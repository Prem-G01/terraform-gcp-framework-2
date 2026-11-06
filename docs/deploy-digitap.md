# Digitap production setup

Target: `prj-dg-api-prod-shared`, Mumbai `asia-south1`, VM zone `asia-south1-a`.
Source: all seven populated sheets in `GCP Resource List Digitap BSA V3.xlsx`.
The project must already exist with billing enabled; this stack does not create or move projects or organization folders.
The supplied name "Digitap Prod Setup" has no confirmed local path or GCP folder ID; the environment is `digitap` in this repository.

## Resources and defaults

Nine primary resources: bucket `dg-api-digitap`, empty secret container
`dg-api-digitap-mysql-connection`, services `dg-api-digitap-backend`,
`dg-api-digitap-ai`, `dg-api-digitap-bsa`, job `dg-api-digitap-bsa-job`,
VM `dg-api-digitap-redis`, Docker repository `dg-api-digitap`, and workflow
`dg-api-digitap-bsa-processing`. API enablements, networking and a runtime account are supporting resources.

The three services use the public Cloud Run hello image until real images are
supplied. They require IAM authentication with all ingress, request billing,
GEN2, concurrency 40, timeout 300s, max 5 instances, 1 CPU, 1Gi memory,
CPU boost disabled. Authenticated access is the user-approved change from the
workbook public-access setting. These endpoints do not implement Digitap.

The job has 1 task, parallelism 1 (equivalent to maximum concurrency for one task),
1 retry, timeout 43200s, 1 CPU and 4Gi memory. It is created but never executed
automatically. Its placeholder command deliberately fails if manually invoked.
Replace the job image and remove command/args before production use.
The workflow deliberately raises an unconfigured error; replace its source before
use. It uses the default compute service account, all-call logging, basic history
and Google-managed encryption as requested. Its application IAM grants are not
created. The dedicated Cloud Run runtime account starts with no project roles;
application IAM and secret injection must be configured with the real workloads.

The MySQL connection secret is automatically replicated, Google encrypted, has no
expiration and has no Terraform-managed secret version. Add the real value outside
Terraform; never put it in YAML, Git or a command line. No MySQL instance is listed
in the workbook, so none is created.

The bucket uses STANDARD regional storage, uniform access, public access
prevention, versioning, and force_destroy=false. Bucket names are globally unique;
an existing bucket needs ownership checks and import or an agreed new name.
The Artifact Registry repository uses Standard Docker, mutable tags (provider
default), Google encryption, cleanup dry run with no deletion policy. The workbook
simultaneously says container scanning disabled and vulnerability scanning enabled;
no scanning override is chosen. Container Scanning API is enabled, but verify the
repository's effective scanning settings and clarify this contradictory requirement.

## Private Redis

New VPC `digitap-prod-vpc`, VM subnet `10.60.1.0/24`, dedicated Cloud Run
subnet `10.60.2.0/24`. Check for overlaps before future VPN/peering connections.
Redis reserves private address `10.60.1.10`; no VM external IP. Only the dedicated
Run subnet can reach Redis TCP/6379. IAP relay addresses can reach SSH/22;
operator IAP and OS Login IAM grants are managed separately.
Cloud Run services and the job use Direct VPC egress for private ranges.
Cloud NAT/router provide package-download egress for the private VM.
No public HTTP rule is created on the Redis VM: there is no HTTP workload.

The workbook machine identifier `e2-custom-small-1024` and Debian 12 / 10 GB
pd-balanced disk are retained. Its claimed 1 vCPU and Intel Broadwell platform
must be checked against E2 shared-core availability; no CPU-platform pin is set.
Startup installs Redis, binds localhost and the reserved private IP, enables AOF,
and generates a password only on the VM in `/etc/redis/digitap.password`.
Distribute client credentials securely separately. Redis TLS is not configured.
Deletion protection is enabled for the VM, services, job, workflow and secret.

## State and deployment

User-selected state bucket: `infrastructere-terraform-logs` in `prj-dg-devops-test`.
The isolated prefix is `digitap-prod`; existing environment state is not reused.
The deployment identity needs state object access there and deployment permissions
in `prj-dg-api-prod-shared`. Existing GitHub workflows remain CallGenie-only;
use the manual commands below for Digitap.

From repository root in PowerShell:

```powershell
python -m engine.cli validate config/environments/digitap
python -m engine.cli render config/environments/digitap --out environments/digitap/.generated/deployment.normalized.json
terraform -chdir=environments/digitap init "-backend-config=backend.hcl"
terraform -chdir=environments/digitap validate
terraform -chdir=environments/digitap plan "-out=digitap.tfplan"
terraform -chdir=environments/digitap show digitap.tfplan
# Apply only the reviewed saved plan:
terraform -chdir=environments/digitap apply digitap.tfplan
```

Inspect the plan for existing-name collisions and changes to existing resources
before applying, because this is a shared production project. Do not import
existing resources without identifying their owner and existing Terraform state.

References: https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/cloud_run_v2_job
and https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/workflows_workflow.

## Deployment status (2026-11-06)

Deployment is complete for the approved infrastructure baseline: all nine primary
resources and supporting resources are recorded as 34 Terraform-managed objects.
State is in `gs://infrastructere-terraform-logs/digitap-prod`.

The user approved keeping all three Cloud Run services authenticated. Their
configuration sets `allow_unauthenticated: false`, and no public invoker IAM
binding is managed. Live IAM checks found no allUsers/allAuthenticatedUsers grant
on the services; unauthenticated HTTP checks returned 403 for all three URLs.
The initial public-access IAM failure is resolved by this approved configuration
change; no additional IAM administration permission is needed for this baseline.

The final apply created workflow `dg-api-digitap-bsa-processing`; its API state
is ACTIVE. The final full Terraform plan reports no changes. Do not apply the
older `digitap.tfplan` or `digitap-remaining.tfplan`: those plans represented the
superseded public-access configuration. The final verification transcript is
`environments/digitap/.generated/final-plan.txt`.

Redis is RUNNING at private IP `10.60.1.10`, with no external IP; serial startup
logs confirm an authenticated Redis PING succeeded. The three services and the
BSA job report Ready. No job execution was started. The MySQL connection secret
has no versions; add its real value securely before application use.
Artifact Registry reports vulnerability scanning SCANNING_ACTIVE.
The project parent is folder `698991527528`, display name
`Prod Shared Environments`; no project move or new GCP folder was performed.

The three services, job and workflow still contain placeholders. Replace their
images/workflow source and configure runtime credentials, resource-scoped IAM,
secret injection and Redis client access before treating Digitap as live.
No workflow or job was executed as part of deployment verification.

Earlier local validation: all 138 tests passed, Terraform validation and the
hardcode/secret scans passed. Current configuration validation has zero errors
and one warning for the missing static Redis cost rate.

Service endpoints (IAM authentication required):

- Backend: https://dg-api-digitap-backend-xufu3pmgea-el.a.run.app
- AI: https://dg-api-digitap-ai-xufu3pmgea-el.a.run.app
- BSA: https://dg-api-digitap-bsa-xufu3pmgea-el.a.run.app
