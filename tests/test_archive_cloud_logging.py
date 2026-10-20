"""Verify complete snapshots, guarded cursors and safe Cloud Logging retries."""
from copy import deepcopy
from datetime import datetime, timezone
import gzip
from io import BytesIO
import json
from types import SimpleNamespace
from urllib import error, parse

import pytest

from scripts.archive_cloud_logging import (
    GoogleClient, LogArchiveError, REQUIRED_PERMISSIONS, main, run_export,
)
from scripts.archive_upload import ArchiveUploadError, NoRedirect

PROJECT = "prj-dg-cl-apps-dev"
BUCKET = "infrastructere-terraform-logs"
PREFIX = "prj-dg-devops-test-callgenie-history/cloud-logging"
CHECKPOINT = "prj-dg-devops-test-callgenie-history/callgenie/cloud-logging-checkpoint.json"
NOW = datetime(2026, 10, 20, 2, 0, tzinfo=timezone.utc)
ENTRY = {"logName": f"projects/{PROJECT}/logs/example", "insertId": "sample",
         "textPayload": "private log content", "receiveTimestamp": "2026-10-20T01:45:00Z"}


class FakeClient:
    def __init__(self, pages, checkpoint=None, permissions=None, commit_error=None):
        self.pages = iter(pages)
        self.checkpoint = checkpoint
        self.permissions = REQUIRED_PERMISSIONS if permissions is None else permissions
        self.commit_error = commit_error
        self.requests = []
        self.commit_attempts = []
        self.saved = None
        self.opener = None

    def token(self):
        return "private-token"

    def json(self, url, payload=None, *, method=None, allow_missing=False):
        self.requests.append((url, deepcopy(payload)))
        if ":testIamPermissions" in url:
            return {"permissions": sorted(self.permissions)}
        if "/v2/entries:list" in url:
            result = next(self.pages)
            if isinstance(result, Exception):
                raise result
            return result
        if "/upload/storage/" in url:
            self.commit_attempts.append((url, deepcopy(payload)))
            if self.commit_error:
                raise self.commit_error
            self.saved = deepcopy(payload)
            return {"generation": "43"}
        if "alt=media" in url:
            return deepcopy(self.checkpoint)
        assert allow_missing
        return {"generation": "42"} if self.checkpoint else None


def export(tmp_path, client, *, uploader=None, snapshot_id="unique", now=NOW):
    return run_export(PROJECT, BUCKET, PREFIX, CHECKPOINT, tmp_path,
                      client=client, uploader=uploader or (lambda *a, **kw: "created"),
                      now=now, snapshot_id=snapshot_id)


def previous_checkpoint():
    return {"version": 1, "source_project": PROJECT,
            "receive_timestamp_through": "2026-10-20T00:50:00.000000Z"}


def test_first_snapshot_exhausts_empty_continuation_pages_before_checkpoint(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("GITHUB_RUN_ID", "123")
    monkeypatch.setenv("GITHUB_RUN_ATTEMPT", "2")
    client = FakeClient([
        {"entries": [ENTRY], "nextPageToken": "page-two"},
        {"nextPageToken": "page-three"},
        {"entries": [dict(ENTRY, insertId="unicode", textPayload="test \u2603")]},
    ])
    uploaded = []

    def upload(path, bucket, prefix, token, **kwargs):
        assert client.saved is None and not client.commit_attempts
        assert bucket == BUCKET and token == "private-token"
        assert prefix == PREFIX + "/20261020T020000000000Z-run-123-attempt-2-unique"
        uploaded.append(path.name)
        return "created"

    manifest = export(tmp_path, client, uploader=upload)
    assert uploaded == ["entries.jsonl.gz", "manifest.json"]
    with gzip.open(tmp_path / "entries.jsonl.gz", "rt", encoding="utf-8") as source:
        rows = [json.loads(line) for line in source]
    assert len(rows) == 2 and rows[1]["textPayload"] == "test \u2603"
    assert manifest["entry_count"] == 2 and manifest["pages"] == 3
    assert manifest["pagination_complete"] and manifest["initial_full_retained_export"]
    queries = [body for url, body in client.requests if "/v2/entries:list" in url]
    assert queries[0]["filter"] == 'receiveTimestamp <= "2026-10-20T01:50:00.000000Z"'
    assert queries[1]["pageToken"] == "page-two" and queries[2]["pageToken"] == "page-three"
    assert queries[0]["orderBy"] == "timestamp desc"
    assert client.saved["receive_timestamp_through"] == "2026-10-20T01:50:00.000000Z"
    cas = parse.parse_qs(parse.urlsplit(client.commit_attempts[0][0]).query)
    assert cas["ifGenerationMatch"] == ["0"] and cas["name"] == [CHECKPOINT]
    output = capsys.readouterr()
    assert "private" not in output.out + output.err


def test_incremental_snapshot_overlaps_one_day_and_uses_read_generation_for_cas(tmp_path):
    client = FakeClient([{"entries": []}], checkpoint=previous_checkpoint())
    manifest = export(tmp_path, client)
    assert not manifest["initial_full_retained_export"]
    assert manifest["query"]["filter"] == (
        'receiveTimestamp > "2026-10-19T00:50:00.000000Z" AND '
        'receiveTimestamp <= "2026-10-20T01:50:00.000000Z"'
    )
    assert any("ifGenerationMatch=42" in url and "alt=media" in url for url, _ in client.requests)
    assert "ifGenerationMatch=42" in client.commit_attempts[0][0]
    assert client.saved["entry_count"] == 0


def test_page_failure_preserves_checkpoint_and_uploads_nothing(tmp_path):
    client = FakeClient([{"entries": [ENTRY], "nextPageToken": "next"},
                         LogArchiveError("Cloud archive request failed (HTTP 503).")],
                        checkpoint=previous_checkpoint())
    uploaded = []
    with pytest.raises(LogArchiveError, match="HTTP 503"):
        export(tmp_path, client, uploader=lambda *a, **kw: uploaded.append(a) or "created")
    assert not uploaded and not client.commit_attempts and client.saved is None


def test_partial_upload_retry_uses_new_snapshot_and_only_success_advances(tmp_path):
    first = FakeClient([{"entries": [ENTRY]}], checkpoint=previous_checkpoint())
    prefixes = []

    def fail_manifest(path, bucket, prefix, token, **kwargs):
        prefixes.append(prefix)
        if path.name == "manifest.json":
            raise ArchiveUploadError("Archive failed (HTTP 503).")
        return "created"

    with pytest.raises(ArchiveUploadError, match="HTTP 503"):
        export(tmp_path / "first", first, uploader=fail_manifest, snapshot_id="failed")
    assert first.saved is None and not first.commit_attempts
    second = FakeClient([{"entries": [ENTRY]}], checkpoint=previous_checkpoint())
    export(tmp_path / "retry", second,
           uploader=lambda p, b, prefix, token, **kw: prefixes.append(prefix) or "created",
           snapshot_id="retry")
    assert prefixes[0] != prefixes[-1] and second.saved is not None


def test_checkpoint_compare_and_swap_conflict_keeps_previous_cursor(tmp_path, capsys):
    previous = previous_checkpoint()
    client = FakeClient([{"entries": [ENTRY]}], checkpoint=previous,
                        commit_error=LogArchiveError("Cloud archive generation precondition failed (HTTP 412)."))
    with pytest.raises(LogArchiveError, match="precondition"):
        export(tmp_path, client)
    assert client.saved is None and client.checkpoint == previous
    assert "checkpoint advanced" not in capsys.readouterr().out


def test_missing_private_log_permission_fails_before_export_or_cursor_access(tmp_path):
    client = FakeClient([], permissions={"logging.logEntries.list"})
    with pytest.raises(LogArchiveError, match="private log entries"):
        export(tmp_path, client)
    assert len(client.requests) == 1 and not client.commit_attempts


def test_repeated_page_token_does_not_advance_cursor(tmp_path):
    client = FakeClient([{"nextPageToken": "same"}, {"nextPageToken": "same"}])
    with pytest.raises(LogArchiveError, match="pagination token"):
        export(tmp_path, client)
    assert not client.commit_attempts


def test_existing_unique_archive_never_advances_cursor(tmp_path):
    client = FakeClient([{"entries": []}])
    with pytest.raises(LogArchiveError, match="already exists"):
        export(tmp_path, client, uploader=lambda *a, **kw: "exists")
    assert not client.commit_attempts


def test_checkpoint_for_another_project_cannot_be_reused(tmp_path):
    client = FakeClient([], checkpoint=dict(previous_checkpoint(), source_project="other-project"))
    with pytest.raises(LogArchiveError, match="source project"):
        export(tmp_path, client)
    assert not client.commit_attempts


@pytest.mark.parametrize("status", [429, 503])
def test_google_client_retries_transient_errors_without_private_details(status, capsys):
    calls, delays = [], []

    def send(req, timeout):
        calls.append(req)
        if len(calls) == 1:
            raise error.HTTPError(req.full_url, status, "private reason", None, BytesIO(b"private body"))
        return BytesIO(b'{"entries": []}')

    client = GoogleClient(opener=SimpleNamespace(open=send), token_provider=lambda: "private-token",
                          sleep=delays.append)
    assert client.json("https://logging.googleapis.com/v2/entries:list", {}) == {"entries": []}
    assert len(calls) == 2 and delays == [1]
    assert "private" not in capsys.readouterr().out


def test_google_client_refreshes_credentials_after_401_and_for_long_queries():
    tokens = iter(["old", "fresh", "later"])
    clock = [0]
    headers = []

    def send(req, timeout):
        headers.append(req.get_header("Authorization"))
        if len(headers) == 1:
            raise error.HTTPError(req.full_url, 401, "private", None, BytesIO())
        return BytesIO(b"{}")

    client = GoogleClient(opener=SimpleNamespace(open=send), token_provider=lambda: next(tokens),
                          sleep=lambda _: None, clock=lambda: clock[0])
    client.json("https://logging.googleapis.com/v2/entries:list", {})
    clock[0] = 2701
    client.json("https://logging.googleapis.com/v2/entries:list", {})
    assert headers == ["Bearer old", "Bearer fresh", "Bearer later"]


def test_missing_checkpoint_is_normal_but_cas_conflict_is_terminal():
    calls = []

    def send(req, timeout):
        calls.append(req)
        status = 404 if len(calls) == 1 else 412
        raise error.HTTPError(req.full_url, status, "private", None, BytesIO(b"private"))

    client = GoogleClient(opener=SimpleNamespace(open=send), token_provider=lambda: "token")
    assert client.json("https://storage.googleapis.com/storage/v1/b/test/o/checkpoint", allow_missing=True) is None
    with pytest.raises(LogArchiveError, match="precondition"):
        client.json("https://storage.googleapis.com/upload/storage/v1/b/test/o", {}, method="POST")
    assert len(calls) == 2


def test_requests_cannot_redirect_tokens_or_use_an_unexpected_host():
    client = GoogleClient(token_provider=lambda: pytest.fail("Unexpected authentication"))
    with pytest.raises(LogArchiveError, match="fixed Google API host"):
        client.json("https://untrusted.example/entries")
    assert NoRedirect().redirect_request(None, None, 302, "Found", {}, "https://untrusted.example") is None


def test_missing_environment_fails_without_cloud_calls(monkeypatch, capsys):
    for key in ("LOG_SOURCE_PROJECT", "ARCHIVE_BUCKET", "ARCHIVE_PREFIX", "LOG_CHECKPOINT"):
        monkeypatch.delenv(key, raising=False)
    assert main() == 1
    assert "are required" in capsys.readouterr().err


def test_unexpected_failure_is_redacted_at_cli_boundary(monkeypatch, capsys):
    import scripts.archive_cloud_logging as module
    for key, value in (("LOG_SOURCE_PROJECT", PROJECT), ("ARCHIVE_BUCKET", BUCKET),
                       ("ARCHIVE_PREFIX", PREFIX), ("LOG_CHECKPOINT", CHECKPOINT)):
        monkeypatch.setenv(key, value)

    def fail(*args, **kwargs):
        raise RuntimeError("private log payload and private-token")

    monkeypatch.setattr(module, "run_export", fail)
    assert module.main() == 1
    captured = capsys.readouterr()
    assert "private" not in captured.out + captured.err
    assert "Cloud log archive failed" in captured.err
