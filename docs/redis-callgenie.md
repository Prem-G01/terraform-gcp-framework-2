# CallGenie Redis startup installation

## Where to make changes

- Installer: `scripts/startup/redis.sh`. Edit installation and Redis settings here.
- VM configuration: `config/environments/callgenie/deployment.yaml`, under
  `resources.vm.instances.dg-cg-redis-vm`:

  ```yaml
  startup_script_file: scripts/startup/redis.sh
  network:
    public_ip: true
    internal_ip: 10.50.1.10
  ```

- Terraform wiring: `modules/compute/vm/main.tf` reads `startup_script_file`
  relative to the repository root, normalizes line endings, and puts its content
  into the VM's `startup-script` metadata. No bucket or VM service account is needed.
- Runtime configuration: `/etc/redis/callgenie.conf` on the Redis VM. Change the
  repository script for lasting changes rather than only editing the VM.

## Installation behavior

The GCE guest agent executes the script as root at boot. On the first successful
run it adds the official Redis APT repository and installs the latest available
stable `redis-server` and `redis-tools` packages for Debian 12. It does not pin a
version number or install a preview release. The exact installed version is
recorded in `/var/lib/callgenie-bootstrap/redis-installed-version.txt`.

Redis is enabled through systemd. Configuration includes:

- Bind addresses `127.0.0.1` and `10.50.1.10`, TCP port `6379`.
- Protected mode and a random password generated locally on the VM.
- `maxmemory 256mb` and `allkeys-lru` for this 1 GB dev cache VM.
- AOF persistence with `appendfsync everysec` on the boot disk. This is not a backup.

A successful authenticated `PING` writes the completion marker
`/var/lib/callgenie-bootstrap/redis-v1.complete`. Subsequent boots start Redis
without reinstalling, upgrading, regenerating the password, or overwriting its
configuration. A failed first run leaves no marker, so it can be retried.
The script itself does not perform upgrades on every reboot.

## Network requirement and selected approach

The approved approach gives **only the Redis VM** an ephemeral public IP for
outbound package downloads. NAT and the dedicated router remain disabled; no VM
service account is attached. The VPC default internet route must remain enabled.
DNS resolution and outbound HTTP/HTTPS to Debian package mirrors and
`packages.redis.io` must be allowed by project and organization policies.
Private Google Access alone cannot reach these external repositories.

The public IP does not add an inbound Redis firewall rule. Redis listens only on
localhost and its private IP; the firewall permits Redis traffic only from the
application VM tags and Cloud Run subnet. SSH remains limited to IAP. The Redis
protocol is password protected but TLS is not configured by this script; configure
TLS before using it for workloads that require encrypted client traffic.

The repository's global private-VM policy still flags `SEC_PUBLIC_VM` for Redis.
The existing audited render override below handles this deliberate exception;
do not downgrade the global security policy. If another security error appears,
resolve it before rendering. An organization policy prohibiting external VM IPs
cannot be bypassed by this local override.

## Deploy from the repository root (PowerShell)

1. Edit the startup script if needed. Save it with LF line endings.
2. Check configuration. The single expected error is `SEC_PUBLIC_VM` on
   `vm.dg-cg-redis-vm`; the cost estimate warning may also be present:

   ```powershell
   python -m engine.cli validate config/environments/callgenie
   ```

3. Render with the documented exception, then initialize and plan:

   ```powershell
   python -m engine.cli render config/environments/callgenie --out environments/callgenie/.generated/deployment.normalized.json --force-security --reason "Approved dev Redis external IP for package downloads without NAT; private Redis bind and restricted ingress"
   terraform -chdir=environments/callgenie init -backend-config="bucket=infrastructere-terraform-logs" -backend-config="prefix=prj-dg-devops-test-callgenie-history/callgenie"
   terraform -chdir=environments/callgenie validate
   terraform -chdir=environments/callgenie plan "-out=callgenie.tfplan"
   ```

4. Review the plan, then deploy:

   ```powershell
   terraform -chdir=environments/callgenie apply callgenie.tfplan
   ```

Terraform finishes creating infrastructure before the startup script necessarily
finishes. An apply succeeding does not prove that Redis installed successfully.
Use the checks below. External IPs can incur charges even with NAT disabled.
The backend bucket is hosted in `prj-dg-devops-test`; the Redis VM and other
application resources stay in `prj-dg-cl-apps-dev`. A workstation still caching
the old backend must use the [central-backend reconnection steps](callgenie-history.md#connect-an-existing-workstation-after-migration).

## Check installation on the Redis VM

Connect through IAP from PowerShell with an identity that has the required IAP
and OS Login permissions:

```powershell
gcloud compute ssh dg-cg-redis-vm --project=prj-dg-cl-apps-dev --zone=asia-south1-a --tunnel-through-iap
```

Run these commands **inside the Linux VM**:

```bash
sudo tail -n 100 /var/log/callgenie-redis-startup.log
sudo journalctl -u google-startup-scripts.service --no-pager -n 100
sudo systemctl status redis-server --no-pager
redis-server --version
sudo cat /var/lib/callgenie-bootstrap/redis-installed-version.txt
sudo ss -lntp | grep ':6379'
sudo bash -c 'REDISCLI_AUTH="$(cat /etc/redis/callgenie.password)" redis-cli --no-auth-warning -h 127.0.0.1 ping'
```

The final command should print `PONG`. The listener should use `127.0.0.1` and
`10.50.1.10`, rather than `0.0.0.0`. The password is in
`/etc/redis/callgenie.password` (root owned, readable by the Redis group).
An authorized operator can retrieve it with:

```bash
sudo cat /etc/redis/callgenie.password
```

Do not commit the password, include it in startup metadata, or paste it into logs.
Supply it to application configuration through your chosen secret-management
process. No Redis secret or application credential injection is created here.
Applications connect to private address `10.50.1.10:6379`; verify with an
appropriate Redis client from an application VM or the Cloud Run workload using
the generated password. An unauthenticated command should return `NOAUTH`.

## Central history and Redis logs

GitHub deployment reports and console archives are retained in the shared
`infrastructere-terraform-logs` bucket in `prj-dg-devops-test`, under
`prj-dg-devops-test-callgenie-history/deployments/callgenie/<run-id>/attempts/<attempt>/`.
Callgenie Cloud Logging snapshots run hourly at minute 17 and write entries and
manifests beneath `prj-dg-devops-test-callgenie-history/cloud-logging/`. They use
a ten-minute cutoff and 24-hour overlap; overlapping snapshots can contain
duplicates. Their checkpoint advances only after all snapshot uploads succeed.
The native `callgenie-central-history` sink also exports records reaching Cloud
Logging at the shared bucket root, in Google's log-type/date hierarchy. Native
exports are batched and may take 2-3 hours to first appear.

`/var/log/callgenie-redis-startup.log` and the Redis/systemd journals shown above
are local VM files. The sink does not upload them automatically. These VMs have
no runtime service account or configured log collector; inspect the local files
through IAP. Shipping their contents to Cloud Logging requires separately
configured collection and credentials. See [history and recovery](callgenie-history.md)
for archive paths, historical Cloud Logging backfill, and coverage limits.

## Retry, change settings, or upgrade later

If installation failed, fix connectivity or the reported package/configuration
error, then run on the VM:

```bash
sudo google_metadata_script_runner startup
```

For script changes, run Terraform plan/apply again to update the metadata, then
rerun the guest script or reboot. A metadata change alone does not execute it on
an already running VM. The completion marker intentionally skips installation
and configuration after the first success.

To deliberately reconfigure or upgrade to the then-latest official package, back
up required data, update/apply the script, and then run on the VM:

```bash
sudo rm -f /var/lib/callgenie-bootstrap/redis-v1.complete
sudo google_metadata_script_runner startup
```

This restarts Redis and may upgrade its major version. Check client compatibility
and release notes first. The password file is preserved on reruns; removing the
VM boot disk loses both local credentials and Redis data. After changing the
private IP, also update `REDIS_BIND_IP` in the script and rerun configuration.

## References

- [Official Redis APT installation](https://redis.io/docs/latest/operate/oss_and_stack/install/install-stack/apt/)
- [GCE Linux startup scripts and rerun/logging commands](https://docs.cloud.google.com/compute/docs/instances/startup-scripts/linux)
