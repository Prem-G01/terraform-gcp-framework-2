# Callgenie monitoring and troubleshooting

## Scope and console pages

The configuration in `prj-dg-cl-apps-dev` includes **36 alert policies, two
dashboards with 28 charts, one email channel, and nine Redis custom metric
descriptors**. Metrics are stored in Cloud Monitoring; VM/application logs and
deployment records follow the existing Cloud Logging and GCS history routes.
Existing Saafe production is unchanged. Open these pages with the Callgenie
project selected:

- [Alerting and incidents](https://console.cloud.google.com/monitoring/alerting?project=prj-dg-cl-apps-dev): filter policy names by `Callgenie Dev`.
- [Dashboards](https://console.cloud.google.com/monitoring/dashboards?project=prj-dg-cl-apps-dev): open either dashboard below.
- [Metrics Explorer](https://console.cloud.google.com/monitoring/metrics-explorer?project=prj-dg-cl-apps-dev): inspect individual metric/resource labels.
- [Logs Explorer](https://console.cloud.google.com/logs/query?project=prj-dg-cl-apps-dev): inspect VM journals, Redis files, and managed-service logs.
- [Cloud SQL Query Insights](https://console.cloud.google.com/sql/instances/dg-api-csql/insights?project=prj-dg-cl-apps-dev): inspect query load when the database receives traffic.

| Configuration key | Dashboard | Charts and coverage |
| --- | --- | --- |
| `callgenie-infrastructure` | Callgenie Dev - VM and Cloud SQL Bottlenecks | 15: VM CPU/memory/filesystems, disk latency/queue/throughput/IOPS, network throughput/drops; SQL CPU/memory/disk/connections/availability/slow queries/deadlocks. |
| `callgenie-application` | Callgenie Dev - Cloud Run, Redis and Firestore | 13: Cloud Run requests/errors/latency/CPU/memory/instances; Firestore requests/latency; Redis health/persistence/memory/clients/latency/evictions/rejections. |

This covers infrastructure and service telemetry. Cloud Run still runs the sample
`hello` image; these charts do not establish real application readiness or add
application traces. SQL query data depends on actual database workload. Public
uptime checks remain disabled because Cloud Run requires IAM authentication.
Cloud Run and Firestore have no absence policies that would treat idle periods
or scale-to-zero as an outage.

## Where to configure monitoring

| Source or location | What it controls |
| --- | --- |
| [Callgenie deployment YAML](../config/environments/callgenie/deployment.yaml) | `notification_channels`, `alert_policies`, `dashboards`, `metric_descriptors`, VM account attachment, and SQL `insights`. |
| [Installer](../scripts/monitoring/install.sh) | Offline agent installation, host metrics/journals, Redis file receivers, and Redis collector service/timer installation. |
| [Redis collector](../scripts/monitoring/redis_metrics.py) | Authenticated local Redis checks and selected numeric custom metrics. |
| [Service](../scripts/monitoring/redis-metrics.service) and [timer](../scripts/monitoring/redis-metrics.timer) | Root collector execution every 60 seconds on Redis. |
| `bootstrap/callgenie` | Monitoring identity and its project roles, managed separately from application state. |
| `/etc/google-cloud-ops-agent/config.yaml` on each VM | Installed receivers/pipelines; lasting changes belong in installer source. |

Terraform manages alerts, channels, dashboards, descriptors, Query Insights, and
VM identity attachment. It does not execute the guest installer. Apply the
reviewed Terraform changes, then run the installer through IAP. Repeat guest
installation after a VM replacement or monitoring-script changes.

All three VMs attach
`callgenie-monitoring@prj-dg-cl-apps-dev.iam.gserviceaccount.com` with the
`cloud-platform` OAuth scope. Bootstrap grants this account only
`roles/monitoring.metricWriter` and `roles/logging.logWriter`. It has no SQL
application credentials or infrastructure administration role. The application
stack's `service_accounts` resource remains disabled; bootstrap owns this account.
Cloud Run's runtime identity is unchanged. CI has separate Monitoring management
permission for Terraform. Attachment changes can briefly stop/restart VMs; those
restarts are approved for this rollout. No NAT, additional external IP, or public
ingress rule is added. Google API access uses Private Google Access.

## Install or reinstall inside the VMs

Use an operator with IAP, OS Login, and sudo access. Prepare a verified offline
Ops Agent `.deb` bundle for **Ubuntu 24.04** on `dg-cl-vm`/`dg-lk-server-vm`, and
**Debian 12** on `dg-cg-redis-vm`. Obtain packages from Google's official signed
repository; verify their hashes against signed metadata. The rollout prepares
agent/dependency packages in `/var/tmp/callgenie-monitoring/packages/` through
the available Google access path. Keep package/version/checksum evidence with
rollout records. Prepare a matching bundle again after an OS or package change.
Google's [offline installation guidance](https://docs.cloud.google.com/monitoring/agent/ops-agent/installation#vms-without-remote-package-access)
explains installation without remote package access.

For the current rollout, Google Ops Agent **2.72.0** bundles for all three VMs
are signature/hash-verified with their required dependencies, staged at that
package path.

The repository installer uses only supplied local packages with `dpkg`. It does
not fetch missing dependencies. It requires `google-cloud-ops-agent` in the
bundle and fails if dependencies are incomplete.

From PowerShell at the repository root, choose a VM and copy all four files.
Repeat for each of the three VM names:

```powershell
$monitoringVm = "dg-cg-redis-vm"
gcloud compute ssh $monitoringVm --project=prj-dg-cl-apps-dev --zone=asia-south1-a --tunnel-through-iap --command="mkdir -p /var/tmp/callgenie-monitoring"
gcloud compute scp scripts/monitoring/install.sh scripts/monitoring/redis_metrics.py scripts/monitoring/redis-metrics.service scripts/monitoring/redis-metrics.timer "${monitoringVm}:/var/tmp/callgenie-monitoring/" --project=prj-dg-cl-apps-dev --zone=asia-south1-a --tunnel-through-iap
gcloud compute ssh $monitoringVm --project=prj-dg-cl-apps-dev --zone=asia-south1-a --tunnel-through-iap
```

Inside that Linux VM, after staging the verified package bundle, use:

| VM | Command |
| --- | --- |
| `dg-cl-vm`, `dg-lk-server-vm` | `sudo bash /var/tmp/callgenie-monitoring/install.sh --package /var/tmp/callgenie-monitoring/packages` |
| `dg-cg-redis-vm` | `sudo bash /var/tmp/callgenie-monitoring/install.sh --package /var/tmp/callgenie-monitoring/packages --redis` |

The installer backs up a different existing agent configuration before replacing
it. It enables 60-second host metrics and systemd journal collection on all VMs.
Redis also receives file log collection and `callgenie-redis-metrics.timer`.
Review the configuration first if an operator has added custom receivers locally.

## Redis metrics and credentials

The collector runs as root and reads `/etc/redis/callgenie.password` locally.
It passes the value to `redis-cli` through `REDISCLI_AUTH`; the password is absent
from command arguments, Ops Agent configuration, Terraform, and Git. Do not
print the file, enable shell tracing, or paste its contents into troubleshooting
output. The collector publishes these `GAUGE` / `DOUBLE` metrics under
`custom.googleapis.com/callgenie/redis/`, using the VM's resource labels:

| Suffix | Meaning |
| --- | --- |
| `up` | 1 after authenticated PING/INFO succeeds; 0 when that check fails. |
| `ping_latency_ms` | Local authenticated PING duration, including `redis-cli` startup. |
| `memory_utilization` | `used_memory / maxmemory`; current maxmemory is 256 MiB. |
| `connected_clients` | Current connected clients. |
| `client_utilization` | Connected clients / configured `maxclients`. |
| `blocked_clients` | Current blocked clients. |
| `evicted_keys_delta` | Evictions since the previous successfully published sample. |
| `rejected_connections_delta` | Rejections since the previous successfully published sample. |
| `persistence_ok` | 1 when reported RDB/AOF statuses are healthy; 0 on a reported failure. |

The two delta values are counts since the previous successful sample, normally
about a minute apart. They are neither fixed per-second rates nor Monitoring
`DELTA`-kind metrics. The first sample establishes a zero baseline; a counter
reset starts a fresh delta. Counter state advances only after successful metric
publication, so an interruption can lengthen the next interval. Redis retains
AOF, its 256 MiB maxmemory limit, and `allkeys-lru`; monitoring does not regenerate
the password or change those settings.

## Alert thresholds and policy keys

All policies select `callgenie-operations-email`, configured for
`premkumar.gunasekaran@docugenieai.com`. This is the configured recipient;
creating the channel does not establish inbox delivery. Reminders repeat hourly.
The strategy auto-closes a no-data incident after 30 minutes. Missing telemetry
alerts do not independently identify the cause.

Filesystem capacity checks exclude read-only loop devices used by Ubuntu system images.

The hold below is the configured condition duration, in addition to collection
and ingestion delay. Zero seconds adds no sustained hold.

| Policy key in deployment YAML | Condition | Hold |
| --- | --- | --- |
| `vm-cpu-high` | CPU >80% | 5 min |
| `vm-memory-high` | Used memory >85% | 5 min |
| `vm-disk-space-high` | Filesystem >85% | 5 min |
| `vm-disk-space-critical` | Filesystem >95% | 2 min |
| `vm-disk-latency` | Mean disk I/O latency >20 ms (20,000 microseconds) | 5 min |
| `vm-network-buffer-drops` | Receive-buffer drop rate >0 | 2 min |
| `vm-down-dg-cg-redis-vm` | Native CPU telemetry absent | 5 min |
| `vm-agent-missing-dg-cg-redis-vm` | Ops Agent memory telemetry absent | 10 min |
| `vm-down-dg-cl-vm` | Native CPU telemetry absent | 5 min |
| `vm-agent-missing-dg-cl-vm` | Ops Agent memory telemetry absent | 10 min |
| `vm-down-dg-lk-server-vm` | Native CPU telemetry absent | 5 min |
| `vm-agent-missing-dg-lk-server-vm` | Ops Agent memory telemetry absent | 10 min |
| `sql-cpu-high` | CPU >80% | 5 min |
| `sql-memory-high` | Memory >85% | 5 min |
| `sql-disk-high` | Disk >85% | 5 min |
| `sql-connections-high` | Connections / limit >80% | 5 min |
| `sql-unavailable` | Reported availability <1 | 2 min |
| `sql-telemetry-missing` | Cloud SQL telemetry absent | 10 min |
| `sql-deadlocks` | Deadlock count >0 in the aligned minute | No additional hold |
| `sql-slow-queries` | Slow-query count >5 per aligned minute | 5 min |
| `run-error-ratio` | 5xx responses / all responses >5% | 5 min |
| `run-p95-latency` | p95 request latency >1,000 ms | 5 min |
| `run-cpu-high` | p95 CPU >80% | 5 min |
| `run-memory-high` | p95 memory >85% | 5 min |
| `run-instance-capacity` | Instances >17 (configured cap 20) | 5 min |
| `firestore-p95-latency` | p95 successful-request latency >1 second | 5 min |
| `firestore-quota-errors` | Resource-exhausted response count >0 | No additional hold |
| `redis-up` | Authenticated local health <1 | 2 min |
| `redis-memory_utilization` | used_memory / maxmemory >80% | 5 min |
| `redis-client_utilization` | connected_clients / maxclients >80% | 5 min |
| `redis-blocked_clients` | Blocked clients >0 | 5 min |
| `redis-ping_latency_ms` | Local authenticated PING >50 ms | 5 min |
| `redis-evicted_keys_delta` | Evictions since previous successful sample >0 | 5 min |
| `redis-rejected_connections_delta` | Rejections since previous successful sample >0 | No additional hold |
| `redis-persistence_ok` | Reported RDB/AOF persistence health <1 | 2 min |
| `redis-collector-missing` | Redis collector heartbeat absent | 5 min |

The six per-VM absence filters use expected Compute Engine instance IDs. Update
these CPU/memory filters and any instance-specific Redis heartbeat filter after
VM replacement, then review/apply the plan. A new VM can retain its old name while
receiving a different numeric ID. Native CPU telemetry absence is held for five
minutes, guest memory absence for ten minutes, and Redis heartbeat absence for
five minutes.

SQL Query Insights is enabled on `dg-api-csql` with a 1,024-character query string
limit. SQL remains Enterprise; the rollout does not upgrade to Enterprise Plus,
supply application SQL passwords, enable application tags, or record client
addresses. Use Query Insights to correlate CPU, slow queries, and deadlocks when
queries run. The slow-query counter follows MySQL's existing `long_query_time`.
See Google's [Query Insights documentation](https://docs.cloud.google.com/sql/docs/mysql/using-query-insights)
for its workload and edition behavior.

## Verify and troubleshoot

Allow roughly 3-5 minutes for fresh agent/custom metrics, then select a suitable
time range and resource labels in Metrics Explorer. Check native CPU,
`agent.googleapis.com/memory/percent_used`, and Redis custom `up`. Native CPU can
remain visible when guest collection fails; memory absence and Redis heartbeat
cover those separate paths.

Inside each Linux VM, inspect service health and recent journals:

```bash
sudo systemctl status 'google-cloud-ops-agent*' --no-pager
sudo journalctl -u google-cloud-ops-agent -u google-cloud-ops-agent-opentelemetry-collector -u google-cloud-ops-agent-fluent-bit --since '-15 minutes' --no-pager
```

On Redis also run:

```bash
sudo systemctl status callgenie-redis-metrics.timer callgenie-redis-metrics.service --no-pager
sudo systemctl list-timers callgenie-redis-metrics.timer --no-pager
sudo journalctl -u callgenie-redis-metrics.service --since '-15 minutes' --no-pager
sudo systemctl start callgenie-redis-metrics.service
```

The collector is a oneshot service and can be inactive between successful timer
runs. Check its last exit status and next timer run. Redis failure can produce
`up=0` while metric publishing itself succeeds. If data is absent, check agent
subservices, account attachment/write roles, VM OAuth scopes, Private Google
Access, and Monitoring/Logging API access. Inspect fixed errors/status codes
without displaying metadata tokens, Redis passwords, or full INFO responses.

From PowerShell, inspect configured resource identifiers:

```powershell
terraform -chdir=environments/callgenie output notification_channel_names
terraform -chdir=environments/callgenie output alert_policy_names
terraform -chdir=environments/callgenie output monitoring_dashboard_ids
```

Empty Cloud Run/Firestore charts during no traffic are expected. SQL query charts
need real queries. Confirm ingestion and filters before changing thresholds;
correlate CPU/memory, disk queues/latency, network drops, and dependent SQL/Redis
services to diagnose bottlenecks.

## Logs, history, and rollout records

Ops Agent sends system journals on all three VMs to Cloud Logging; Redis also
collects `/var/log/redis/redis-server.log` and
`/var/log/callgenie-redis-startup.log`. Native `callgenie-central-history` exports
incoming records at `gs://infrastructere-terraform-logs/` using Google's
log-type/date paths. Hourly snapshots also copy records beneath
`gs://infrastructere-terraform-logs/prj-dg-devops-test-callgenie-history/cloud-logging/`.
Terraform/deployment history remains in that same environment folder. Store
package verification, rollout logs, and operational checks under
`gs://infrastructere-terraform-logs/prj-dg-devops-test-callgenie-history/history/monitoring-rollout/`.
Keep passwords and tokens out of these records. Native export is batched; allow
time for new records to appear in both archive routes. See [history and recovery](callgenie-history.md)
for overlap/checkpoints and retention limits. Files outside configured receivers
need explicit collection configuration.

Google's [Ops Agent configuration guide](https://docs.cloud.google.com/monitoring/agent/ops-agent/configuration)
describes the receivers and pipelines used by the installer.
