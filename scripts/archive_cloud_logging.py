"""Archive retained Cloud Logging records, then advance a guarded checkpoint.

Snapshots intentionally overlap by one day. Deduplicate downstream by logName,
insertId and timestamp when counting records across snapshots. Log payloads and
credentials are never written to the console.
"""
from __future__ import annotations

import base64
from datetime import datetime, timedelta, timezone
import gzip
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import time
from urllib import error, parse, request
import uuid

try:
    from .archive_upload import ArchiveUploadError, NoRedirect, access_token, upload_file
except ImportError:  # Executing `python scripts/archive_cloud_logging.py`.
    from archive_upload import ArchiveUploadError, NoRedirect, access_token, upload_file

DELAY = timedelta(minutes=10)
OVERLAP = timedelta(days=1)
REQUIRED_PERMISSIONS = {"logging.logEntries.list", "logging.privateLogEntries.list"}
HOSTS = {"logging.googleapis.com", "cloudresourcemanager.googleapis.com", "storage.googleapis.com"}


class LogArchiveError(ArchiveUploadError):
    """A safe-to-print failure without credentials, log entries or API bodies."""


def timestamp(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")


def parse_timestamp(value: str) -> datetime:
    try:
        result = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if result.tzinfo is None:
            raise ValueError
        return result.astimezone(timezone.utc)
    except (AttributeError, TypeError, ValueError):
        raise LogArchiveError("The log checkpoint contains an invalid timestamp.") from None


class GoogleClient:
    """Use fixed HTTPS hosts, bounded retries and refreshed private credentials."""

    def __init__(self, *, opener=None, token_provider=None, sleep=None, clock=None):
        self.opener = opener or request.build_opener(NoRedirect())
        self.token_provider = token_provider or access_token
        self.sleep = sleep or time.sleep
        self.clock = clock or time.monotonic
        self._token = None
        self._token_time = 0

    def token(self, force=False):
        if force or self._token is None or self.clock() - self._token_time >= 2700:
            self._token = self.token_provider()
            self._token_time = self.clock()
        return self._token

    def json(self, url, payload=None, *, method=None, allow_missing=False):
        parts = parse.urlsplit(url)
        if parts.scheme != "https" or parts.netloc not in HOSTS:
            raise LogArchiveError("Cloud archive requests require a fixed Google API host.")
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8") if payload is not None else None
        for attempt in range(6):
            req = request.Request(url, data=body, method=method, headers={
                "Authorization": "Bearer " + self.token(),
                "Content-Type": "application/json",
            })
            try:
                with self.opener.open(req, timeout=180) as response:
                    return json.load(response)
            except error.HTTPError as exc:
                status = exc.code
                exc.close()
                if status == 404 and allow_missing:
                    return None
                if status == 401 and attempt < 5:
                    self.token(force=True)
                elif status == 412:
                    raise LogArchiveError("Cloud archive generation precondition failed (HTTP 412).") from None
                elif (status != 429 and not 500 <= status <= 599) or attempt == 5:
                    raise LogArchiveError(f"Cloud archive request failed (HTTP {status}).") from None
            except (error.URLError, TimeoutError, OSError):
                if attempt == 5:
                    raise LogArchiveError("Cloud archive request exhausted connection retries.") from None
            except (ValueError, UnicodeError):
                raise LogArchiveError("Cloud archive received an invalid API response.") from None
            if attempt < 5:
                self.sleep(min(2 ** attempt, 16))
        raise LogArchiveError("Cloud archive request exhausted retries.")


def object_url(bucket, name):
    return ("https://storage.googleapis.com/storage/v1/b/" + parse.quote(bucket, safe="")
            + "/o/" + parse.quote(name, safe=""))


def load_checkpoint(client, bucket, name, project):
    url = object_url(bucket, name)
    metadata = client.json(url, allow_missing=True)
    if metadata is None:
        return None, "0"
    generation = str(metadata.get("generation", ""))
    if not generation.isdigit() or int(generation) < 1:
        raise LogArchiveError("The log checkpoint has invalid object metadata.")
    saved = client.json(url + "?" + parse.urlencode({"alt": "media", "ifGenerationMatch": generation}))
    if not isinstance(saved, dict) or saved.get("version") != 1 or saved.get("source_project") != project:
        raise LogArchiveError("The log checkpoint does not match the source project or supported format.")
    parse_timestamp(saved.get("receive_timestamp_through"))
    return saved, generation


def save_checkpoint(client, bucket, name, generation, saved):
    query = parse.urlencode({"uploadType": "media", "name": name, "ifGenerationMatch": generation})
    url = ("https://storage.googleapis.com/upload/storage/v1/b/"
           + parse.quote(bucket, safe="") + "/o?" + query)
    client.json(url, saved, method="POST")


def file_summary(path):
    sha, md5 = hashlib.sha256(), hashlib.md5()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            sha.update(chunk)
            md5.update(chunk)
    return {"bytes": path.stat().st_size, "sha256": sha.hexdigest(),
            "md5_base64": base64.b64encode(md5.digest()).decode("ascii")}


def run_export(project, bucket, prefix, checkpoint_name, directory, *, client=None,
               uploader=None, now=None, snapshot_id=None):
    """Stream every page; publish both files before a compare-and-swap checkpoint."""
    client = client or GoogleClient()
    uploader = uploader or upload_file
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    permissions = client.json(
        "https://cloudresourcemanager.googleapis.com/v1/projects/"
        + parse.quote(project, safe="") + ":testIamPermissions",
        {"permissions": sorted(REQUIRED_PERMISSIONS)},
    )
    if REQUIRED_PERMISSIONS - set(permissions.get("permissions", [])):
        raise LogArchiveError("Cloud archive requires access to both standard and private log entries.")
    previous, generation = load_checkpoint(client, bucket, checkpoint_name, project)
    now = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    cutoff = now - DELAY
    query_filter = f'receiveTimestamp <= "{timestamp(cutoff)}"'
    if previous:
        previous_cutoff = parse_timestamp(previous["receive_timestamp_through"])
        if previous_cutoff > cutoff:
            raise LogArchiveError("The log checkpoint is ahead of the delayed export cutoff.")
        lower_bound = previous_cutoff - OVERLAP
        query_filter = f'receiveTimestamp > "{timestamp(lower_bound)}" AND ' + query_filter
    payload = {"resourceNames": ["projects/" + project], "filter": query_filter,
               "orderBy": "timestamp desc", "pageSize": 1000}
    snapshot_id = snapshot_id or uuid.uuid4().hex
    run_id = os.environ.get("GITHUB_RUN_ID", "local")
    attempt = os.environ.get("GITHUB_RUN_ATTEMPT", "1")
    if (run_id != "local" and not run_id.isdigit()) or not attempt.isdigit():
        raise LogArchiveError("The CI archive run identifier is invalid.")
    archive_prefix = (prefix.strip("/") + "/" + now.strftime("%Y%m%dT%H%M%S%fZ")
                      + f"-run-{run_id}-attempt-{attempt}-{snapshot_id}")
    entries_path = directory / "entries.jsonl.gz"
    entry_count = pages = 0
    tokens = set()
    with entries_path.open("wb") as raw:
        with gzip.GzipFile(filename="", fileobj=raw, mode="wb", mtime=0) as stream:
            while True:
                response = client.json("https://logging.googleapis.com/v2/entries:list", payload)
                pages += 1
                for entry in response.get("entries", []):
                    if not isinstance(entry, dict):
                        raise LogArchiveError("Cloud Logging returned an invalid entry.")
                    stream.write(json.dumps(entry, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n")
                    entry_count += 1
                continuation = response.get("nextPageToken")
                if not continuation:
                    break
                if not isinstance(continuation, str) or continuation in tokens:
                    raise LogArchiveError("Cloud Logging returned an invalid pagination token.")
                tokens.add(continuation)
                payload["pageToken"] = continuation
    manifest = {
        "version": 1, "source_project": project,
        "created_at_utc": timestamp(now), "receive_timestamp_through": timestamp(cutoff),
        "previous_receive_timestamp_through": previous["receive_timestamp_through"] if previous else None,
        "initial_full_retained_export": previous is None, "overlap_seconds": int(OVERLAP.total_seconds()),
        "ingestion_delay_seconds": int(DELAY.total_seconds()),
        "query": {k: v for k, v in payload.items() if k != "pageToken"},
        "read_permissions_confirmed": sorted(REQUIRED_PERMISSIONS),
        "entry_count": entry_count, "pages": pages, "pagination_complete": True,
        "entries": dict(file_summary(entries_path), uri=f"gs://{bucket}/{archive_prefix}/entries.jsonl.gz"),
        "github_run_id": run_id, "github_run_attempt": attempt,
        "notes": ["The first snapshot includes all retained entries through the delayed receiveTimestamp cutoff.",
                  "Subsequent snapshots overlap by one day to capture indexing delays; duplicates across snapshots are expected.",
                  "Records already expired from Cloud Logging retention and VM-local logs never sent to Cloud Logging are unavailable."],
    }
    manifest_path = directory / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    for path in (entries_path, manifest_path):
        result = uploader(path, bucket, archive_prefix, client.token(), opener=client.opener)
        if result != "created":
            raise LogArchiveError("The unique archive snapshot already exists; its checkpoint was preserved.")
    checkpoint = {"version": 1, "source_project": project,
                  "receive_timestamp_through": timestamp(cutoff),
                  "last_snapshot": f"gs://{bucket}/{archive_prefix}/manifest.json",
                  "entry_count": entry_count, "pages": pages}
    save_checkpoint(client, bucket, checkpoint_name, generation, checkpoint)
    print(f"Archived {entry_count} Cloud Logging entries across {pages} pages; checkpoint advanced.")
    return manifest


def main():
    names = ("LOG_SOURCE_PROJECT", "ARCHIVE_BUCKET", "ARCHIVE_PREFIX", "LOG_CHECKPOINT")
    values = [os.environ.get(name, "").strip() for name in names]
    if not all(values):
        print("LOG_SOURCE_PROJECT, ARCHIVE_BUCKET, ARCHIVE_PREFIX and LOG_CHECKPOINT are required.", file=sys.stderr)
        return 1
    try:
        with tempfile.TemporaryDirectory(prefix="callgenie-cloud-logging-") as directory:
            run_export(*values, directory)
    except ArchiveUploadError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    except Exception:
        # Unexpected API/library exceptions can include response or log payloads.
        print("Cloud log archive failed; review the archive workflow without exposing log payloads.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
