"""Create immutable CI archive objects without destination metadata permissions."""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import subprocess
import sys
import time
from urllib import error, parse, request


class ArchiveUploadError(Exception):
    """A safe-to-print upload failure without credentials or response bodies."""


class NoRedirect(request.HTTPRedirectHandler):
    """Keep the bearer token on the fixed Google Storage endpoint."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def access_token() -> str:
    """Capture the federated gcloud token privately; never pass it in argv."""
    try:
        result = subprocess.run(
            ["gcloud", "auth", "print-access-token"],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        raise ArchiveUploadError("Archive authentication is unavailable.") from None
    token = result.stdout.strip()
    if result.returncode or not token or "\n" in token or "\r" in token:
        raise ArchiveUploadError("Archive authentication failed.")
    return token


def upload_file(
    path: Path,
    bucket: str,
    prefix: str,
    token: str,
    *,
    opener=None,
    sleep=None,
    attempts: int = 3,
) -> str:
    """Stream a create-only media upload; an existing object is left intact."""
    opener = opener or request.build_opener(NoRedirect())
    sleep = sleep or time.sleep
    object_name = f"{prefix.strip('/')}/{path.name}"
    query = parse.urlencode({
        "uploadType": "media",
        "name": object_name,
        "ifGenerationMatch": "0",
    })
    url = (
        "https://storage.googleapis.com/upload/storage/v1/b/"
        f"{parse.quote(bucket, safe='')}/o?{query}"
    )
    for attempt in range(attempts):
        try:
            with path.open("rb") as source:
                upload = request.Request(
                    url,
                    data=source,
                    headers={
                        "Authorization": f"Bearer {token}",
                        "Content-Type": "application/octet-stream",
                        "Content-Length": str(path.stat().st_size),
                    },
                    method="POST",
                )
                with opener.open(upload, timeout=120) as response:
                    response.read()
            print(f"Archived: {path.name}")
            return "created"
        except error.HTTPError as exc:
            status = exc.code
            exc.close()
            if status == 412:
                print(f"Already archived: {path.name}")
                return "exists"
            if status != 429 and not 500 <= status <= 599:
                raise ArchiveUploadError(
                    f"Archive failed: {path.name} (HTTP {status})."
                ) from None
            failure = f"HTTP {status}"
        except (error.URLError, TimeoutError, OSError):
            failure = "connection or file error"
        if attempt + 1 < attempts:
            print(f"Retrying archive: {path.name}")
            sleep(2 ** attempt)
    raise ArchiveUploadError(f"Archive failed: {path.name} ({failure}).")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("files", nargs="+", type=Path)
    args = parser.parse_args(argv)
    bucket = os.environ.get("ARCHIVE_BUCKET", "").strip()
    prefix = os.environ.get("ARCHIVE_PREFIX", "").strip("/")
    try:
        if not bucket or not prefix:
            raise ArchiveUploadError("ARCHIVE_BUCKET and ARCHIVE_PREFIX are required.")
        if any(not path.is_file() for path in args.files):
            raise ArchiveUploadError("An archive source file is missing.")
        if len({path.name for path in args.files}) != len(args.files):
            raise ArchiveUploadError("Archive source filenames must be unique.")
        token = access_token()
    except ArchiveUploadError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    failed = False
    for path in args.files:
        try:
            upload_file(path, bucket, prefix, token)
        except ArchiveUploadError as exc:
            print(str(exc), file=sys.stderr)
            failed = True
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(main())
