# Callgenie central history and recovery

Callgenie uses one Cloud Storage bucket,
`gs://prj-dg-devops-test-callgenie-history`, in `prj-dg-devops-test`. Its application
resources, CI service accounts, and GitHub Workload Identity Federation stay in
`prj-dg-cl-apps-dev`. The application bucket `dg-cl-dev` is separate. Saafe
production resources, state, and deployment settings are unchanged.

## What is stored where

All paths below are relative to the central bucket.

| Path | Contents |
| --- | --- |
| `callgenie/default.tfstate` | Active application state; object versioning retains subsequent state history. Terraform creates a transient lock in `callgenie/`. |
| `deployments/callgenie/<run-id>/attempts/<attempt>/` | Available validation reports, audit files, plan text/JSON, apply outputs, validation/Terraform console logs, and `github-console-logs.zip`. |
| `bootstrap/callgenie/terraform.tfstate` | Protected backup of the separate local CI/bootstrap state. Refresh after bootstrap changes. |
| `history/legacy-tfstate/<generation>/<original-name>` | Former state-bucket objects preserved with their source generation in the path. |
| `history/legacy-artifacts/<generation>/<original-name>` | Former artifact-bucket objects and bootstrap backups preserved by source generation. |
| `history/migration/manifest.json` | Migration inventory and verification record. |
| `logging-backfill/callgenie/<timestamp>/entries.jsonl.gz` | Historical Cloud Logging records exported before the new sink's cutover; the accompanying `manifest.json` records coverage. |
| `<log-type>/YYYY/MM/DD/` | New Cloud Logging exports organized automatically by Google, for example `cloudaudit.googleapis.com/activity/2026/10/20/`. |

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
versioning, and seven-day soft delete. It has no automatic lifecycle deletion of
history. No bucket retention lock is configured because Terraform must delete
its transient lock object after each operation.

Callgenie's existing plan/apply accounts can manage active state under
`callgenie/` and list bucket object names. They can create deployment archives
under `deployments/callgenie/`, without permission to replace or delete them.
The sink's separate writer identity creates log-export objects. Neither CI
account receives project-wide administration access in the DevOps project.
State and plan files can contain sensitive resource values; use an authorized
operator account to inspect or recover them.

## Cloud Logging coverage

The project sink `callgenie-central-history` belongs to `prj-dg-cl-apps-dev` and
exports all matching incoming Cloud Logging records to the central bucket. Its
filter is empty. This includes records received by Cloud Logging; it does not
enable disabled logging categories or collect files from a VM by itself.

Cloud Storage exports are hourly batches, and the first objects may take
2-3 hours to appear. Google determines their log-type/date paths; the sink does
not accept a custom `logs/callgenie/` prefix. Check configuration with:

```powershell
gcloud logging sinks describe callgenie-central-history --project=prj-dg-cl-apps-dev --format="yaml(name,destination,filter,writerIdentity)"
gcloud storage ls "gs://prj-dg-devops-test-callgenie-history/"
```

Sinks route new records. Historical backfill is a separate export into
`logging-backfill/callgenie/<timestamp>/`; inspect its manifest for the exact
query, time range, and entry count. A bounded export covers only that recorded
range, not every record that may still exist in Cloud Logging. Additional old
records can be copied using Google's [historical copy procedure](https://docs.cloud.google.com/logging/docs/routing/copy-logs).

Redis startup logs and systemd journals remain on the VM unless a collector
ships them to Cloud Logging. The current VMs have no attached runtime service
accounts or configured log collector. Use the [Redis IAP checks](redis-callgenie.md#check-installation-on-the-redis-vm)
to read those local logs. See Google's [Cloud Storage export behavior](https://docs.cloud.google.com/logging/docs/export/storage)
for batching and log organization.

## Migration and verification

The former buckets were `prj-dg-cl-apps-dev-tfstate` and
`prj-dg-cl-apps-dev-tf-artifacts` in the application project. Their migration
keeps the application state prefix `callgenie` and preserves old objects by
generation under `history/legacy-*`. The bootstrap/WIF identities are retained.
Both `state_bucket` and `artifact_bucket` in the Callgenie `ENVIRONMENTS_JSON`
entry point to the new central bucket.

During a migration, prevent concurrent plan/apply runs, preserve the old state
and bootstrap backups, transfer historical objects, then switch the backend.
Verify state lineage, serial, and resource inventory against the authoritative
source and run an application plan to check for unintended infrastructure
changes. Validate CI bucket access and archived files before removing the old
buckets. The migration manifest records the transfer; do not repeat migration
from an outdated copy after the new backend becomes authoritative.

## Connect an existing workstation after migration

If `.terraform` still refers to the old bucket, reconnect to the already
migrated backend without copying stale source state over it:

```powershell
terraform -chdir=environments/callgenie init -reconfigure -backend-config="bucket=prj-dg-devops-test-callgenie-history" -backend-config="prefix=callgenie"
terraform -chdir=environments/callgenie state list
terraform -chdir=environments/callgenie plan -var="project_id=prj-dg-cl-apps-dev"
```

Use `-migrate-state` only for the original controlled transfer from the
authoritative backend, before cutover. Fresh checkouts can use normal `init`
with the central bucket and `callgenie` prefix. Never initialize against an
empty backend and apply in an attempt to rediscover deployed resources.

## Recover state

For application state recovery, stop concurrent CI runs, back up the current
state, and inspect a central bucket object version or preserved legacy
generation. Confirm its lineage, serial, and resources before restoring with
Terraform's state tooling. Do not use `state push -force` to bypass a lineage
or serial mismatch. Recovery changes Terraform's records; review a plan before
applying any infrastructure changes. See the [GCS backend recovery guidance](https://developer.hashicorp.com/terraform/language/backend/gcs).

On a new workstation, restore the bootstrap backup into
`bootstrap/callgenie/terraform.tfstate` before planning bootstrap updates:

```powershell
gcloud storage cp "gs://prj-dg-devops-test-callgenie-history/bootstrap/callgenie/terraform.tfstate" "bootstrap/callgenie/terraform.tfstate"
terraform -chdir=bootstrap/callgenie init
terraform -chdir=bootstrap/callgenie plan "-var-file=callgenie.tfvars.example"
```

Keep that downloaded state outside Git and avoid overwriting a newer local
bootstrap state. The bootstrap state is separate from `callgenie/default.tfstate`;
neither file substitutes for the other.
