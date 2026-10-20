"""Verify Redis health, authentication privacy, metric writes and counter safety."""
from copy import deepcopy
from datetime import datetime, timezone
from io import BytesIO
import json
import os
from pathlib import Path
from types import SimpleNamespace
from urllib import error, parse

import pytest

from scripts.monitoring import redis_metrics as module

SECRET = "private-test-password"
INFO = """# Server
redis_version:8.10.2
# Memory
used_memory:128
maxmemory:256
# Clients
connected_clients:10
maxclients:100
blocked_clients:2
# Stats
evicted_keys:100
rejected_connections:20
# Persistence
rdb_last_bgsave_status:ok
aof_last_write_status:ok
"""
NOW = datetime(2026, 10, 20, 3, 0, tzinfo=timezone.utc)
LABELS = {"project_id": "prj-dg-cl-apps-dev", "instance_id": "12345", "zone": "asia-south1-a"}


def password_file(tmp_path):
    path = tmp_path / "password"
    path.write_text(SECRET + "\n", encoding="utf-8")
    return path


def redis_runner(info=INFO, ping="PONG", maxclients="maxclients\n100", calls=None):
    def run(args, **kwargs):
        if calls is not None:
            calls.append((args, kwargs))
        if args[-1] == "PING":
            text = ping
        elif args[-2:] == ["INFO", "ALL"]:
            text = info
        elif args[-3:] == ["CONFIG", "GET", "maxclients"]:
            text = maxclients
        else:
            raise AssertionError("Unexpected Redis command")
        return SimpleNamespace(returncode=0, stdout=text, stderr="private diagnostic")
    return run


class Transport:
    def __init__(self, *, status=None, project=LABELS["project_id"]):
        self.requests = []
        self.status = status
        self.project = project

    def open(self, req, timeout):
        self.requests.append(req)
        url = parse.urlsplit(req.full_url)
        if url.hostname == "169.254.169.254":
            assert req.get_header("Metadata-flavor") == "Google"
            suffix = url.path.split("/computeMetadata/v1/", 1)[1]
            values = {"project/project-id": self.project, "instance/id": LABELS["instance_id"],
                      "instance/zone": "projects/1047815843325/zones/" + LABELS["zone"],
                      "instance/service-accounts/default/token": json.dumps({"access_token": "private-token"})}
            return BytesIO(values[suffix].encode())
        assert url.hostname == "monitoring.googleapis.com" and url.scheme == "https"
        if self.status:
            raise error.HTTPError(req.full_url, self.status, "private server detail", None,
                                  BytesIO(b"private response body"))
        return BytesIO(b"{}")


def test_redis8_info_parsing_and_ratios_are_correct():
    info = module.parse_info(INFO + "\nunknown:private:value\n")
    assert info["unknown"] == "private:value"
    metrics, saved = module.build_metrics(info, 1.25,
        {"counters": {"evicted_keys": 90, "rejected_connections": 18}})
    assert metrics["up"] == 1 and metrics["memory_utilization"] == 0.5
    assert metrics["client_utilization"] == 0.1 and metrics["blocked_clients"] == 2
    assert metrics["ping_latency_ms"] == 1.25 and metrics["persistence_ok"] == 1
    assert metrics["evicted_keys_delta"] == 10 and metrics["rejected_connections_delta"] == 2
    assert set(metrics) == set(module.METRIC_DEFINITIONS)
    assert saved == {"version": 1, "counters": {"evicted_keys": 100, "rejected_connections": 20}}
    assert "private" not in json.dumps(metrics) + json.dumps(saved)


def test_first_sample_and_counter_resets_do_not_produce_negative_deltas():
    info = module.parse_info(INFO)
    first, _ = module.build_metrics(info, 1, {})
    assert first["evicted_keys_delta"] == first["rejected_connections_delta"] == 0
    reset, _ = module.build_metrics(info, 1,
        {"counters": {"evicted_keys": 500, "rejected_connections": 500}})
    assert reset["evicted_keys_delta"] == 100 and reset["rejected_connections_delta"] == 20
    malformed, _ = module.build_metrics(info, 1, {"counters": []})
    assert malformed["evicted_keys_delta"] == 0


def test_unbounded_memory_and_clients_omit_ratios_instead_of_dividing_by_zero():
    info = module.parse_info(INFO)
    info.update(maxmemory="0", maxclients="0")
    metrics, _ = module.build_metrics(info, 1, {})
    assert "memory_utilization" not in metrics and "client_utilization" not in metrics
    assert metrics["up"] == 1


@pytest.mark.parametrize("field", ["rdb_last_bgsave_status", "aof_last_write_status"])
def test_persistence_failure_is_reported(field):
    info = module.parse_info(INFO)
    info[field] = "err"
    assert module.build_metrics(info, 1, {})[0]["persistence_ok"] == 0


def test_collect_authenticates_only_through_child_environment(tmp_path, capsys):
    calls = []
    times = iter([1.0, 1.002])
    metrics, _ = module.collect({}, password_file=password_file(tmp_path),
                                runner=redis_runner(calls=calls), clock=lambda: next(times))
    assert metrics["up"] == 1 and metrics["ping_latency_ms"] == pytest.approx(2)
    for args, kwargs in calls:
        assert SECRET not in repr(args)
        assert kwargs["env"]["REDISCLI_AUTH"] == SECRET
        assert kwargs["capture_output"] and kwargs["timeout"] == 3
        assert "shell" not in kwargs
    captured = capsys.readouterr()
    assert SECRET not in captured.out + captured.err


@pytest.mark.parametrize("ping", ["NOAUTH Authentication required.", "WRONGPASS private-test-password", ""])
def test_authentication_or_connection_failure_publishes_only_down(tmp_path, ping, capsys):
    metrics, saved = module.collect({}, password_file=password_file(tmp_path), runner=redis_runner(ping=ping))
    assert metrics == {"up": 0.0} and saved is None
    captured = capsys.readouterr()
    assert SECRET not in captured.out + captured.err


def test_missing_maxclients_uses_config_get_without_secret_arguments(tmp_path):
    calls = []
    metrics, _ = module.collect({}, password_file=password_file(tmp_path),
                                runner=redis_runner(info=INFO.replace("maxclients:100\n", ""), calls=calls))
    assert metrics["client_utilization"] == 0.1
    assert calls[-1][0][-3:] == ["CONFIG", "GET", "maxclients"]
    assert SECRET not in repr(calls[-1][0])


def test_malformed_info_is_down_and_does_not_reset_counter_state(tmp_path):
    metrics, saved = module.collect({}, password_file=password_file(tmp_path),
                                    runner=redis_runner(info="NOAUTH private-test-password"))
    assert metrics == {"up": 0.0} and saved is None


def test_publish_sends_numeric_gauges_and_correct_compute_resource_without_secrets():
    transport = Transport()
    module.publish({"up": 1.0, "memory_utilization": 0.5}, LABELS, "private-token", transport=transport, now=NOW)
    req = transport.requests[0]
    assert req.get_header("Authorization") == "Bearer private-token"
    assert req.get_method() == "POST" and req.full_url.endswith("/projects/prj-dg-cl-apps-dev/timeSeries")
    body = json.loads(req.data)
    assert len(body["timeSeries"]) == 2
    for series in body["timeSeries"]:
        assert series["resource"] == {"type": "gce_instance", "labels": LABELS}
        assert series["metricKind"] == "GAUGE" and series["valueType"] == "DOUBLE"
        assert series["metric"]["type"].startswith(module.METRIC_PREFIX)
        point = series["points"][0]
        assert point["interval"]["endTime"] == "2026-10-20T03:00:00.000000Z"
        assert isinstance(point["value"]["doubleValue"], float)
    assert SECRET.encode() not in req.data and b"private-token" not in req.data


def test_complete_sample_uses_metadata_identity_and_advances_state_after_upload(tmp_path, capsys):
    transport = Transport()
    state = tmp_path / "state.json"
    metrics = module.run_once(state_file=state, password_file=password_file(tmp_path),
                              transport=transport, runner=redis_runner(), now=NOW)
    assert len(metrics) == 9 and len(transport.requests) == 5
    assert module.load_state(state)["counters"]["evicted_keys"] == 100
    if os.name != "nt":
        assert state.stat().st_mode & 0o077 == 0
    captured = capsys.readouterr()
    assert captured.out.strip() == "Published 9 Redis health metrics."
    assert SECRET not in captured.out + captured.err and "private-token" not in captured.out + captured.err


def test_failed_metric_upload_preserves_existing_counter_state(tmp_path):
    state = tmp_path / "state.json"
    previous = {"version": 1, "counters": {"evicted_keys": 90, "rejected_connections": 18}}
    state.write_text(json.dumps(previous), encoding="utf-8")
    original = state.read_bytes()
    with pytest.raises(module.MonitoringError):
        module.run_once(state_file=state, password_file=password_file(tmp_path),
                        transport=Transport(status=403), runner=redis_runner(), now=NOW)
    assert state.read_bytes() == original


def test_down_sample_does_not_lose_counters_from_the_last_success(tmp_path):
    state = tmp_path / "state.json"
    previous = {"version": 1, "counters": {"evicted_keys": 90, "rejected_connections": 18}}
    state.write_text(json.dumps(previous), encoding="utf-8")
    original = state.read_bytes()
    result = module.run_once(state_file=state, password_file=password_file(tmp_path),
                             transport=Transport(), runner=redis_runner(ping="NOAUTH"), now=NOW)
    assert result == {"up": 0.0} and state.read_bytes() == original


def test_transient_api_errors_are_retried_but_credentials_are_not_logged(capsys):
    calls, delays = [], []

    def send(req, timeout):
        calls.append(req)
        if len(calls) == 1:
            raise error.HTTPError(req.full_url, 503, "private-token", None, BytesIO(b"private body"))
        return BytesIO(b"{}")

    module.publish({"up": 1.0}, LABELS, "private-token", transport=SimpleNamespace(open=send),
                   sleep=delays.append, now=NOW)
    assert len(calls) == 2 and delays == [1]
    assert "private" not in capsys.readouterr().out


def test_metadata_for_another_project_cannot_publish_or_fetch_a_token():
    transport = Transport(project="production-other")
    with pytest.raises(module.MonitoringError):
        module.identity_and_token(transport=transport)
    assert len(transport.requests) == 1


def test_redirects_cannot_forward_metadata_or_bearer_credentials():
    assert module.NoRedirect().redirect_request(
        None, None, 302, "Found", {}, "https://untrusted.example") is None


def test_main_redacts_unexpected_errors(monkeypatch, capsys):
    def fail():
        raise RuntimeError(SECRET + " private-token")
    monkeypatch.setattr(module, "run_once", fail)
    assert module.main() == 1
    captured = capsys.readouterr()
    assert captured.err.strip() == "Redis monitoring could not publish metrics."
    assert SECRET not in captured.out + captured.err
