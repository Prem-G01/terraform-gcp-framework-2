"""Check atomic archive uploads, append-only IAM behavior, and secret redaction."""
from io import BytesIO
from types import SimpleNamespace
from urllib import error, parse

import pytest

from scripts.archive_upload import ArchiveUploadError, NoRedirect, upload_file


def test_upload_streams_authenticated_create_only_request(tmp_path, capsys):
    source = tmp_path / "github-console-logs.zip"
    source.write_bytes(b"archive contents")
    requests = []

    def send(upload, timeout):
        requests.append(upload)
        url = parse.urlsplit(upload.full_url)
        assert url.scheme == "https" and url.hostname == "storage.googleapis.com"
        assert upload.get_method() == "POST"
        assert parse.parse_qs(url.query) == {
            "uploadType": ["media"],
            "name": ["deployments/callgenie/123/attempts/1/github-console-logs.zip"],
            "ifGenerationMatch": ["0"],
        }
        assert upload.get_header("Authorization") == "Bearer private-test-token"
        assert upload.get_header("Content-length") == str(source.stat().st_size)
        assert upload.data.read() == b"archive contents"
        assert timeout == 120
        return BytesIO(b"{}")

    result = upload_file(
        source, "example-bucket", "deployments/callgenie/123/attempts/1",
        "private-test-token", opener=SimpleNamespace(open=send),
    )
    assert result == "created" and len(requests) == 1
    output = capsys.readouterr()
    assert "private-test-token" not in output.out + output.err


def test_existing_object_is_skipped_without_reading_it(tmp_path, capsys):
    source = tmp_path / "validation.json"
    source.write_bytes(b"{}")
    calls = []

    def send(upload, timeout):
        calls.append(upload.get_method())
        raise error.HTTPError(
            upload.full_url, 412, "private response detail", None,
            BytesIO(b"private response body"),
        )

    assert upload_file(
        source, "example-bucket", "deployments/callgenie/123/attempts/1",
        "private-test-token", opener=SimpleNamespace(open=send),
    ) == "exists"
    assert calls == ["POST"]
    output = capsys.readouterr()
    assert "Already archived: validation.json" in output.out
    assert "private" not in output.out + output.err


@pytest.mark.parametrize("status", [429, 503])
def test_transient_server_errors_are_retried_with_fresh_file_stream(tmp_path, status):
    source = tmp_path / "plan.txt"
    source.write_bytes(b"plan")
    calls, delays = [], []

    def send(upload, timeout):
        calls.append(upload.data.read())
        if len(calls) == 1:
            raise error.HTTPError(upload.full_url, status, "retry", None, BytesIO())
        return BytesIO(b"{}")

    assert upload_file(
        source, "example-bucket", "deployments/callgenie/123/attempts/1",
        "private-test-token", opener=SimpleNamespace(open=send), sleep=delays.append,
    ) == "created"
    assert calls == [b"plan", b"plan"] and delays == [1]


def test_authorization_error_fails_without_retry_or_response_details(tmp_path):
    source = tmp_path / "plan.txt"
    source.write_bytes(b"plan")
    calls, delays = [], []

    def send(upload, timeout):
        calls.append(upload.get_method())
        raise error.HTTPError(upload.full_url, 403, "private response", None, BytesIO())

    with pytest.raises(ArchiveUploadError, match=r"Archive failed: plan.txt \(HTTP 403\)\."):
        upload_file(
            source, "example-bucket", "deployments/callgenie/123/attempts/1",
            "private-test-token", opener=SimpleNamespace(open=send), sleep=delays.append,
        )
    assert calls == ["POST"] and not delays


def test_timeouts_stop_after_bounded_retries_without_private_details(tmp_path):
    source = tmp_path / "plan.txt"
    source.write_bytes(b"plan")
    calls, delays = [], []

    def send(upload, timeout):
        calls.append(upload.get_method())
        raise TimeoutError("private connection detail")

    with pytest.raises(ArchiveUploadError, match="connection or file error"):
        upload_file(
            source, "example-bucket", "deployments/callgenie/123/attempts/1",
            "private-test-token", opener=SimpleNamespace(open=send), sleep=delays.append,
        )
    assert calls == ["POST"] * 3 and delays == [1, 2]


def test_bearer_token_is_never_redirected_to_another_host():
    assert NoRedirect().redirect_request(
        None, None, 302, "Found", {}, "https://other-host.example/upload"
    ) is None
