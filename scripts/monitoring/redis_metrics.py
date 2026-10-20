"""Publish local Redis health without exposing its password or INFO payload."""
from __future__ import annotations

from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from urllib import error, parse, request

PASSWORD_FILE = Path("/etc/redis/callgenie.password")
STATE_FILE = Path("/var/lib/callgenie-monitoring/redis-counters.json")
EXPECTED_PROJECT = "prj-dg-cl-apps-dev"
METRIC_PREFIX = "custom.googleapis.com/callgenie/redis/"
METRIC_DEFINITIONS = {
    "up": {"unit": "1", "description": "Authenticated Redis PING and INFO health, 1 healthy and 0 unavailable."},
    "ping_latency_ms": {"unit": "ms", "description": "Local authenticated redis-cli PING elapsed time, including client startup."},
    "memory_utilization": {"unit": "1", "description": "Redis used_memory divided by configured maxmemory."},
    "connected_clients": {"unit": "1", "description": "Current connected Redis clients."},
    "client_utilization": {"unit": "1", "description": "Connected clients divided by configured maxclients."},
    "blocked_clients": {"unit": "1", "description": "Current blocked Redis clients."},
    "evicted_keys_delta": {"unit": "1", "description": "Keys evicted since the previous successful sample, normally 60 seconds."},
    "rejected_connections_delta": {"unit": "1", "description": "Connections rejected since the previous successful sample, normally 60 seconds."},
    "persistence_ok": {"unit": "1", "description": "Redis RDB and, when reported, AOF last-write status, 1 healthy and 0 failed."},
}


class MonitoringError(Exception):
    """Safe error type; callers log a fixed message instead of exception text."""


class NoRedirect(request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def opener():
    # Metadata and Google APIs are reached directly, including on private VMs.
    return request.build_opener(request.ProxyHandler({}), NoRedirect())


def parse_info(text):
    result = {}
    for line in text.splitlines():
        if line and not line.startswith("#") and ":" in line:
            key, value = line.split(":", 1)
            result[key] = value.strip()
    return result


def number(info, key):
    value = float(info[key])
    if not math.isfinite(value) or value < 0:
        raise ValueError
    return value


def build_metrics(info, ping_ms, previous):
    """Select numeric fields only; counter resets start a fresh positive delta."""
    if not info.get("redis_version"):
        raise MonitoringError
    used, maximum = number(info, "used_memory"), number(info, "maxmemory")
    clients, blocked = number(info, "connected_clients"), number(info, "blocked_clients")
    metrics = {"up": 1.0, "ping_latency_ms": max(0.0, ping_ms),
               "connected_clients": clients, "blocked_clients": blocked}
    if maximum:
        metrics["memory_utilization"] = used / maximum
    maxclients = number(info, "maxclients") if info.get("maxclients") else 0
    if maxclients:
        metrics["client_utilization"] = clients / maxclients
    statuses = [info.get("rdb_last_bgsave_status")]
    if "aof_last_write_status" in info:
        statuses.append(info["aof_last_write_status"])
    metrics["persistence_ok"] = float(all(status == "ok" for status in statuses))
    counters = {}
    prior = previous.get("counters", {}) if isinstance(previous, dict) else {}
    if not isinstance(prior, dict):
        prior = {}
    for field, name in (("evicted_keys", "evicted_keys_delta"),
                        ("rejected_connections", "rejected_connections_delta")):
        current = int(info[field])
        if current < 0:
            raise ValueError
        old = prior.get(field)
        if not isinstance(old, int) or isinstance(old, bool) or old < 0:
            delta = 0
        else:
            delta = current - old if current >= old else current
        metrics[name] = float(delta)
        counters[field] = current
    return metrics, {"version": 1, "counters": counters}


def redis_command(command, password, *, runner=None):
    runner = runner or subprocess.run
    environment = dict(os.environ, REDISCLI_AUTH=password)
    try:
        result = runner(["redis-cli", "--no-auth-warning", "--raw", "-h", "127.0.0.1",
                         "-p", "6379", *command], env=environment, capture_output=True,
                        text=True, timeout=3, check=False)
        if result.returncode:
            raise MonitoringError
        return result.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        raise MonitoringError from None


def collect(previous, *, password_file=PASSWORD_FILE, runner=None, clock=None):
    """A failed/authentication-denied Redis check still publishes up=0."""
    clock = clock or time.perf_counter
    try:
        password = Path(password_file).read_text(encoding="utf-8").strip()
        if not password or "\n" in password or "\r" in password:
            raise MonitoringError
        started = clock()
        if redis_command(["PING"], password, runner=runner) != "PONG":
            raise MonitoringError
        elapsed = (clock() - started) * 1000
        info = parse_info(redis_command(["INFO", "ALL"], password, runner=runner))
        if not info.get("maxclients"):
            try:
                maximum = redis_command(["CONFIG", "GET", "maxclients"], password, runner=runner).splitlines()
                if len(maximum) == 2 and maximum[0] == "maxclients":
                    info["maxclients"] = maximum[1]
            except MonitoringError:
                pass
        return build_metrics(info, elapsed, previous)
    except (OSError, ValueError, KeyError, MonitoringError):
        return {"up": 0.0}, None


def metadata(path, *, transport):
    url = "http://169.254.169.254/computeMetadata/v1/" + path
    req = request.Request(url, headers={"Metadata-Flavor": "Google"})
    with transport.open(req, timeout=2) as response:
        return response.read().decode("utf-8").strip()


def identity_and_token(*, transport):
    project = metadata("project/project-id", transport=transport)
    if project != EXPECTED_PROJECT:
        raise MonitoringError
    labels = {"project_id": project,
              "instance_id": metadata("instance/id", transport=transport),
              "zone": metadata("instance/zone", transport=transport).rsplit("/", 1)[-1]}
    token = json.loads(metadata("instance/service-accounts/default/token", transport=transport)).get("access_token")
    if not token or not isinstance(token, str) or "\n" in token or "\r" in token:
        raise MonitoringError
    return labels, token


def publish(metrics, labels, token, *, transport=None, now=None, sleep=None):
    transport = transport or opener()
    sleep = sleep or time.sleep
    now = now or datetime.now(timezone.utc)
    end = now.astimezone(timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")
    series = []
    for name, value in metrics.items():
        if name not in METRIC_DEFINITIONS or not math.isfinite(value):
            raise MonitoringError
        series.append({"metric": {"type": METRIC_PREFIX + name},
                       "resource": {"type": "gce_instance", "labels": dict(labels)},
                       "metricKind": "GAUGE", "valueType": "DOUBLE",
                       "points": [{"interval": {"endTime": end}, "value": {"doubleValue": float(value)}}]})
    if not series or len(series) > 200:
        raise MonitoringError
    url = ("https://monitoring.googleapis.com/v3/projects/"
           + parse.quote(labels["project_id"], safe="") + "/timeSeries")
    body = json.dumps({"timeSeries": series}, separators=(",", ":")).encode("utf-8")
    for attempt in range(3):
        req = request.Request(url, data=body, method="POST", headers={
            "Authorization": "Bearer " + token, "Content-Type": "application/json"})
        try:
            with transport.open(req, timeout=6) as response:
                response.read()
            return
        except error.HTTPError as exc:
            status = exc.code
            exc.close()
            if (status != 429 and not 500 <= status <= 599) or attempt == 2:
                raise MonitoringError from None
        except (error.URLError, TimeoutError, OSError):
            if attempt == 2:
                raise MonitoringError from None
        sleep(2 ** attempt)
    raise MonitoringError


def load_state(path):
    try:
        saved = json.loads(Path(path).read_text(encoding="utf-8"))
        return saved if isinstance(saved, dict) and saved.get("version") == 1 else {}
    except (OSError, ValueError):
        return {}


def save_state(path, saved):
    path = Path(path)
    fd, temporary = tempfile.mkstemp(prefix="redis-counters-", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(saved, stream)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def run_once(*, state_file=STATE_FILE, password_file=PASSWORD_FILE, transport=None,
             runner=None, clock=None, now=None):
    transport = transport or opener()
    previous = load_state(state_file)
    metrics, saved = collect(previous, password_file=password_file, runner=runner, clock=clock)
    labels, token = identity_and_token(transport=transport)
    publish(metrics, labels, token, transport=transport, now=now)
    if saved is not None:
        save_state(state_file, saved)
    print(f"Published {len(metrics)} Redis health metrics.")
    return metrics


def main():
    try:
        run_once()
    except Exception:
        # Errors from subprocesses/HTTP libraries can contain secret values.
        print("Redis monitoring could not publish metrics.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
