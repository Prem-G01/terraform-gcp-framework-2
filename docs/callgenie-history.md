# Callgenie central history and recovery

Callgenie stores its state, deployment history, and Cloud Logging snapshots in
`gs://infrastructere-terraform-logs/prj-dg-devops-test-callgenie-history/`.
The shared bucket `infrastructere-terraform-logs` belongs to `prj-dg-devops-test`;
`prj-dg-devops-test-callgenie-history` is Callgenie's folder prefix. Application
resources, CI service accounts, and GitHub Workload Identity Federation stay in
`prj-dg-cl-apps-dev`. The application bucket `dg-cl-dev` is separate. Existing
Saafe production resources, buckets, backends, and deployment settings are unchanged.

## What is stored where

The following paths are relative to the Callgenie folder
`gs://infrastructere-terraform-logs/prj-dg-devops-test-callgenie-history/`.

| Path | Contents |
| --- | --- |
| `callgenie/default.tfstate` | Active application state, with object versions retained. Terraform creates a transient lock in `callgenie/`. |
| `deployments/callgenie/<run-id>/attempts/<attempt>/` | Available validation reports, audit files, plan text/JSON, apply outputs, validation/Terraform console logs, and `github-console-logs.zip`. |
| `bootstrap/callgenie/terraform.tfstate` | Protected backup of the separate local CI/bootstrap state. Refresh after bootstrap changes. |
| `history/legacy-tfstate/<generation>/<original-name>` | Former application-project state-bucket objects preserved by source generation. |
| `history/legacy-artifacts/<generation>/<original-name>` | Former application-project artifact-bucket objects and bootstrap backups preserved by source generation. |
| `history/` | Migration inventories, verification records, and other preserved historical records. |
| `logging-backfill/callgenie/<timestamp>/entries.jsonl.gz` | Earlier historical Cloud Logging exports; the accompanying manifest records their coverage. |
| `cloud-logging/<UTC-snapshot>/entries.jsonl.gz` | Hourly Cloud Logging snapshots, with a manifest recording query coverage, entry counts, and checksums. |
| `callgenie/cloud-logging-checkpoint.json` | Checkpoint for the last fully uploaded Cloud Logging snapshot. |

Native Cloud Logging exports are the authorized exception to this folder layout.
They appear at the shared bucket root under Google's log-type/date paths, for
example `gs://infrastructere-terraform-logs/cloudaudit.googleapis.com/activity/2026/10/20/`.
The native sink cannot assign a custom object prefix. Both this native export
and the snapshots inside Callgenie's folder are enabled.

`plan.yml` and `apply.yml` upload reports even after a failed step when cloud
authentication is available. A failed run may have only some files. The
`archive-logs.yml` workflow runs after a Callgenie Plan/Apply completes and
downloads that attempt's complete GitHub console ZIP. It uses trusted default
branch code and never executes code or extracts an archive from the source run.
Attempt directories and atomic create-only uploads preserve previous archives on
reruns. The shared `scripts/archive_upload.py` uploader streams to Google's media
upload endpoint with `ifGenerationMatch=0`; it never reads destination metadata
or requires permission to overwrite/delete archive objects. Existing objects are
left intact. Transient connection errors, HTTP 429, and server errors have bounded
retries; authorization errors still fail the archive step.
Earlier GitHub runs can be backfilled while their logs remain available in GitHub.

## Access and history protection

The bucket uses uniform access, enforced public-access prevention, object
versioning, seven-day soft delete, and Terraform `prevent_destroy = true`.
It has no automatic lifecycle deletion of history. No bucket retention lock is
configured because Terraform must delete its transient lock object.

Callgenie's existing plan/apply accounts can manage active state under
`prj-dg-devops-test-callgenie-history/callgenie/` and list bucket object names.
Their deployment archive access creates objects only under
`prj-dg-devops-test-callgenie-history/deployments/callgenie/`.
The snapshot identity reads Callgenie's retained Cloud Logging records, creates
snapshots inside its configured logging prefix, and updates the checkpoint.
The sink's separate writer identity creates native log-export objects.
Neither CI account receives project-wide storage administration in the DevOps
project. State and plan files can contain sensitive resource values; use an
authorized operator account to inspect or recover them.

## Cloud Logging coverage

The project sink `callgenie-central-history` belongs to `prj-dg-cl-apps-dev` and
targets `storage.googleapis.com/infrastructere-terraform-logs`. Its empty filter
exports incoming Cloud Logging records to the shared bucket. This covers records
received by Cloud Logging; it does not enable disabled logging categories or
collect files from a VM by itself.

Native Cloud Storage exports are hourly batches, and the first objects may take
2-3 hours to appear. Google determines their log-type/date paths at the bucket
root. Check configuration with:

```powershell
gcloud logging sinks describe callgenie-central-history --project=prj-dg-cl-apps-dev --format="yaml(name,destination,filter,writerIdentity)"
gcloud storage ls "gs://infrastructere-terraform-logs/"
gcloud storage ls "gs://infrastructere-terraform-logs/prj-dg-devops-test-callgenie-history/cloud-logging/"
```

The hourly GitHub Actions snapshot job runs at minute 47 of each hour in IST
(`17 * * * *` in UTC); GitHub can delay scheduled jobs. It uses
`scripts/archive_cloud_logging.py` to copy Cloud Logging entries into Callgenie's
folder. The first successful snapshot queries all currently retained records
available to the identity, up to a cutoff ten minutes before the export. Later
snapshots resume from the checkpoint with a 24-hour overlap to catch delayed
records. Overlapping snapshots can contain duplicates; deduplicate when combining
them for analysis. Records that become queryable more than 24 hours after their receiveTimestamp require another
historical backfill.

The job writes compressed entries and their manifest before advancing the
checkpoint. The checkpoint update uses a generation-match precondition
(compare-and-swap), so a failed or competing upload cannot silently advance
coverage. Inspect each manifest for its actual query, time range, counts, and
checksums. Native routing and folder snapshots intentionally retain some of the
same records. Neither can recover entries that expired from Cloud Logging before
they were archived.

Older `logging-backfill/callgenie/<timestamp>/` exports retain their original
manifests and bounded coverage. Additional retained records can be copied using
Google's [historical copy procedure](https://docs.cloud.google.com/logging/docs/routing/copy-logs).
Monitoring installs Ops Agent on all three VMs to send system journals to Cloud
Logging. Redis additionally collects its server and startup log files. The
bootstrap-managed monitoring-only identity has metric/log write roles; the custom
collector does not log passwords or full INFO responses. These records then
follow both native export and hourly folder snapshots described above. Files
outside configured sources need an explicit receiver. See [monitoring setup](monitoring-callgenie.md)
and the [Redis IAP checks](redis-callgenie.md#check-installation-on-the-redis-vm) for verification.
Package verification and operational rollout records belong under Callgenie's
`history/monitoring-rollout/` folder. See Google's [Cloud Storage export behavior](https://docs.cloud.google.com/logging/docs/export/storage)
for native batching and log organization.

## Shared bucket and future environments

The Callgenie entry in `ENVIRONMENTS_JSON` uses these storage values; keep its
existing WIF and CI service-account fields alongside them:

```json
{
  "state_bucket": "infrastructere-terraform-logs",
  "artifact_bucket": "infrastructere-terraform-logs",
  "state_prefix": "prj-dg-devops-test-callgenie-history/callgenie",
  "artifact_prefix": "prj-dg-devops-test-callgenie-history/deployments/callgenie",
  "logging_prefix": "prj-dg-devops-test-callgenie-history/cloud-logging"
}
```

The isolated bootstrap configures `storage_project_id = "prj-dg-devops-test"`,
`central_bucket_name = "infrastructere-terraform-logs"`, and
`history_prefix = "prj-dg-devops-test-callgenie-history"`. Its outputs provide
the bucket and prefix fields used by CI.

For each future environment, choose a distinct folder inside this same bucket.
Configure that environment's `state_prefix`, `artifact_prefix`, and `logging_prefix`
and scope its CI permissions to those paths. Reuse the existing bucket; do not
create another bucket or declare the shared bucket as a separately owned resource
in another environment's Terraform state. Native Cloud Logging exports remain at
the root if that environment also enables a native Cloud Storage sink. This
layout does not migrate or change the existing Saafe production setup.

## Migration and verification

Historical source buckets were `prj-dg-cl-apps-dev-tfstate` and
`prj-dg-cl-apps-dev-tf-artifacts` in the application project. Their objects were
preserved under `history/legacy-*` when Callgenie first moved to a dedicated
central bucket named `prj-dg-devops-test-callgenie-history`.
That dedicated bucket is now a migration source: its contents move beneath the
identically named folder in `infrastructere-terraform-logs`, retaining their
relative paths and historical records. Retire the source bucket only after the
copy, state verification, and CI access checks succeed. The bootstrap/WIF
identities are retained.

During migration, prevent concurrent plan/apply runs, preserve old state and
bootstrap backups, transfer historical objects, then switch the backend.
Verify state lineage, serial, and resource inventory against the authoritative
source and run an application plan to check for unintended infrastructure
changes. Validate CI access and archives before removing the source bucket.
Migration manifests record transfers; do not repeat migration from an outdated
copy after the shared backend becomes authoritative.

## Connect an existing workstation after migration

If `.terraform` still refers to an old bucket, reconnect to the already migrated
backend without copying stale source state over it:

```powershell
terraform -chdir=environments/callgenie init -reconfigure -backend-config="bucket=infrastructere-terraform-logs" -backend-config="prefix=prj-dg-devops-test-callgenie-history/callgenie"
terraform -chdir=environments/callgenie state list
terraform -chdir=environments/callgenie plan -var="project_id=prj-dg-cl-apps-dev"
```

Use `-migrate-state` only for the original controlled transfer from the
authoritative backend, before cutover. Fresh checkouts use normal `init` with the
same bucket and full prefix. Never initialize against an empty backend and apply
in an attempt to rediscover deployed resources.

## Recover state

For application state recovery, stop concurrent CI runs, back up the current
state, and inspect a shared-bucket object version or preserved legacy generation.
Confirm its lineage, serial, and resources before restoring with Terraform's
state tooling. Do not use `state push -force` to bypass a lineage or serial
mismatch. Recovery changes Terraform's records; review a plan before applying
infrastructure changes. See the [GCS backend recovery guidance](https://developer.hashicorp.com/terraform/language/backend/gcs).

On a new workstation, restore the bootstrap backup into
`bootstrap/callgenie/terraform.tfstate` before planning bootstrap updates:

```powershell
gcloud storage cp "gs://infrastructere-terraform-logs/prj-dg-devops-test-callgenie-history/bootstrap/callgenie/terraform.tfstate" "bootstrap/callgenie/terraform.tfstate"
terraform -chdir=bootstrap/callgenie init
terraform -chdir=bootstrap/callgenie plan "-var-file=callgenie.tfvars.example"
```

Keep that downloaded state outside Git and avoid overwriting newer local
bootstrap state. Bootstrap state is separate from the application state at
`prj-dg-devops-test-callgenie-history/callgenie/default.tfstate`; neither file
substitutes for the other.
