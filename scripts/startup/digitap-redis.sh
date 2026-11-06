#!/usr/bin/env bash
# Debian 12 Redis bootstrap. Runs as root through the GCE guest agent.
# Requires outbound access to Debian mirrors and packages.redis.io.
set -Eeuo pipefail
umask 027
exec > >(tee -a /var/log/digitap-redis-startup.log) 2>&1
trap 'echo "Redis bootstrap failed at line ${LINENO}. Check repository connectivity and this log." >&2' ERR

STATE_DIR=/var/lib/digitap-bootstrap
MARKER="$STATE_DIR/redis-v1.complete"
REDIS_BIND_IP=10.60.1.10
REDIS_MAXMEMORY=256mb

install -d -m 0750 "$STATE_DIR"
exec 9>"$STATE_DIR/redis.lock"
flock -n 9 || exit 0
if [[ -f "$MARKER" ]]; then
  systemctl enable --now redis-server
  echo "Redis bootstrap already completed; retaining installed version and credentials."
  exit 0
fi

. /etc/os-release
if [[ "$ID" != debian || "$VERSION_ID" != 12 ]]; then
  echo "This script supports Debian 12 only." >&2
  exit 1
fi
export DEBIAN_FRONTEND=noninteractive
APT_OPTIONS=(-o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 -o APT::Update::Error-Mode=any -o DPkg::Lock::Timeout=180)
echo "Installing Redis. Outbound repository access is required; Private Google Access alone is insufficient."
apt-get "${APT_OPTIONS[@]}" update
apt-get "${APT_OPTIONS[@]}" install -y --no-install-recommends ca-certificates curl gnupg openssl
key_file=$(mktemp)
trap 'rm -f "$key_file"' EXIT
curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 --max-time 120 https://packages.redis.io/gpg -o "$key_file"
gpg --batch --yes --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg "$key_file"
chmod 0644 /usr/share/keyrings/redis-archive-keyring.gpg
printf 'deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb bookworm main\n' > /etc/apt/sources.list.d/redis.list
# Prefer Redis's own stable packages over the older Debian distribution build.
cat > /etc/apt/preferences.d/digitap-redis <<'PREFERENCES'
Package: redis-server redis-tools
Pin: origin packages.redis.io
Pin-Priority: 1001
PREFERENCES
apt-get "${APT_OPTIONS[@]}" update
apt-get "${APT_OPTIONS[@]}" install -y --no-install-recommends redis-server redis-tools

# Do not replace an existing password when retrying a partially completed bootstrap.
if [[ ! -s /etc/redis/digitap.password ]]; then
  openssl rand -hex 32 > /etc/redis/digitap.password
fi
chown root:redis /etc/redis/digitap.password
chmod 0640 /etc/redis/digitap.password
password=$(cat /etc/redis/digitap.password)
cat > /etc/redis/digitap.conf <<EOF
# Managed by scripts/startup/digitap-redis.sh. Keep credentials on this VM.
bind 127.0.0.1 $REDIS_BIND_IP
protected-mode yes
port 6379
requirepass $password
maxmemory $REDIS_MAXMEMORY
maxmemory-policy allkeys-lru
appendonly yes
appendfsync everysec
EOF
unset password
chown root:redis /etc/redis/digitap.conf
chmod 0640 /etc/redis/digitap.conf
# Keep the include last so these values override the packaged defaults.
sed -i '\|^include /etc/redis/digitap.conf$|d' /etc/redis/redis.conf
printf '\ninclude /etc/redis/digitap.conf\n' >> /etc/redis/redis.conf
printf 'vm.overcommit_memory = 1\n' > /etc/sysctl.d/60-digitap-redis.conf
sysctl -p /etc/sysctl.d/60-digitap-redis.conf
systemctl enable redis-server
systemctl restart redis-server
healthy=false
for attempt in $(seq 1 30); do
  if [[ "$(REDISCLI_AUTH="$(cat /etc/redis/digitap.password)" redis-cli --no-auth-warning -h 127.0.0.1 ping 2>/dev/null || true)" == PONG ]]; then
    healthy=true
    break
  fi
  sleep 2
done
if [[ "$healthy" != true ]]; then
  echo "Redis did not pass the authenticated PING check." >&2
  exit 1
fi
redis-server --version
redis-server --version > "$STATE_DIR/redis-installed-version.txt"
date -u +%FT%TZ > "$MARKER"
echo "Redis bootstrap complete; authenticated PING succeeded. Password is stored only on the VM."
