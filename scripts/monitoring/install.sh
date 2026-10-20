#!/usr/bin/env bash
# Install only from an operator-provided, verified offline .deb bundle.
set -Eeuo pipefail
umask 077
trap 'echo "Callgenie monitoring installation failed; inspect package dependencies and service status." >&2' ERR

package_path=
redis_enabled=false
while (($#)); do
  case "$1" in
    --package) [[ $# -ge 2 ]] || { echo "--package requires a path." >&2; exit 2; }; package_path=$2; shift 2 ;;
    --redis) redis_enabled=true; shift ;;
    *) echo "Usage: install.sh --package FILE_OR_DIRECTORY [--redis]" >&2; exit 2 ;;
  esac
done
[[ $EUID -eq 0 ]] || { echo "Run this installer as root." >&2; exit 2; }
[[ -n "$package_path" ]] || { echo "An offline package path is required." >&2; exit 2; }
. /etc/os-release
[[ "$ID:$VERSION_ID" == ubuntu:24.04 || "$ID:$VERSION_ID" == debian:12 ]] || {
  echo "Only Ubuntu 24.04 and Debian 12 are supported by this installer." >&2; exit 2;
}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ "$redis_enabled" == true ]]; then
  command -v python3 >/dev/null
  command -v redis-cli >/dev/null
  [[ -s /etc/redis/callgenie.password ]] || { echo "The existing Redis password file is required." >&2; exit 2; }
  for source in redis_metrics.py redis-metrics.service redis-metrics.timer; do
    [[ -f "$script_dir/$source" ]] || { echo "The Redis monitoring installation bundle is incomplete." >&2; exit 2; }
  done
fi
packages=()
if [[ -d "$package_path" ]]; then
  shopt -s nullglob
  packages=("$package_path"/*.deb)
elif [[ -f "$package_path" ]]; then
  packages=("$package_path")
fi
((${#packages[@]})) || { echo "No offline Debian packages were supplied." >&2; exit 2; }
agent_found=false
for package in "${packages[@]}"; do
  [[ "$(dpkg-deb --field "$package" Package)" != google-cloud-ops-agent ]] || agent_found=true
done
[[ "$agent_found" == true ]] || { echo "The bundle must contain google-cloud-ops-agent." >&2; exit 2; }
# dpkg never fetches missing dependencies from the network.
dpkg --install "${packages[@]}"

temporary_config=$(mktemp)
trap 'rm -f -- "$temporary_config"' EXIT
cat > "$temporary_config" <<'YAML'
metrics:
  receivers:
    hostmetrics:
      type: hostmetrics
      collection_interval: 60s
  service:
    pipelines:
      default_pipeline:
        receivers: [hostmetrics]
logging:
  receivers:
    system_journal:
      type: systemd_journald
  service:
    pipelines:
      default_pipeline:
        receivers: [system_journal]
YAML
if [[ "$redis_enabled" == true ]]; then
  # Journal and application-file receivers cover different sources.
  cat >> "$temporary_config" <<'YAML'
      redis_files:
        receivers: [redis_files]
YAML
  # Insert receivers under logging.receivers without adding any Redis password.
  python3 - "$temporary_config" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
text = text.replace("    system_journal:\n", "    redis_files:\n      type: files\n      include_paths:\n        - /var/log/redis/redis-server.log\n        - /var/log/callgenie-redis-startup.log\n    system_journal:\n", 1)
path.write_text(text)
PY
fi
install -d -o root -g root -m 0750 /etc/google-cloud-ops-agent
if [[ -f /etc/google-cloud-ops-agent/config.yaml ]] && ! cmp -s "$temporary_config" /etc/google-cloud-ops-agent/config.yaml; then
  install -o root -g root -m 0600 /etc/google-cloud-ops-agent/config.yaml "/etc/google-cloud-ops-agent/config.yaml.before-callgenie.$(date -u +%Y%m%dT%H%M%S).bak"
fi
install -o root -g root -m 0600 "$temporary_config" /etc/google-cloud-ops-agent/config.yaml
systemctl enable google-cloud-ops-agent
systemctl restart google-cloud-ops-agent
systemctl is-active --quiet google-cloud-ops-agent
if [[ "$redis_enabled" == true ]]; then
  install -d -o root -g root -m 0700 /var/lib/callgenie-monitoring
  install -o root -g root -m 0755 "$script_dir/redis_metrics.py" /usr/local/sbin/callgenie-redis-metrics.py
  install -o root -g root -m 0644 "$script_dir/redis-metrics.service" /etc/systemd/system/callgenie-redis-metrics.service
  install -o root -g root -m 0644 "$script_dir/redis-metrics.timer" /etc/systemd/system/callgenie-redis-metrics.timer
  systemctl daemon-reload
  systemctl enable --now callgenie-redis-metrics.timer
  systemctl start callgenie-redis-metrics.service
fi
echo "Callgenie monitoring installed; host metrics and system logs are enabled."
