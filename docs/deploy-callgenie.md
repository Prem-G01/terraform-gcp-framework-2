# CallGenie development deployment

The configuration is derived from all nine sheets of CallGenie Dev Requirements-v1.xlsx
and the subsequent decisions: separate Redis VM, operator-managed access, a sample
Cloud Run image until the application is ready, and private infrastructure by default.

## Project and state

The target GCP project is `prj-dg-cl-apps-dev`, configured in
`config/environments/callgenie/deployment.yaml` and
`environments/callgenie/variables.tf`. Keep both values aligned when changing
projects. The framework does not create GCP projects or billing links.

Use an existing state bucket and a unique `callgenie` prefix. Do not copy another
environment's .terraform directory, local state, or backend metadata.

## Resource inventory

Ten primary resources: bucket dg-cl-dev; two empty secret containers
dg-api-token-private-key-cl and dg-api-mysql-connection-cl; Cloud Run dg-api-backend-cl;
Cloud SQL dg-api-csql; Artifact Registry dg-api; Firestore (default); and VMs
dg-lk-server-vm, dg-cl-vm, dg-cg-redis-vm. Networking, API enablements, the reserved address, and related resources increase
Terraform's total. Dedicated runtime service-account creation is disabled.

The bucket name is copied exactly from the workbook and must be globally available.

## Network and access decisions

- Mumbai asia-south1, VM zone asia-south1-a.
- New custom VPC callgenie-dev-vpc, VM subnet callgenie-dev-private-subnet (10.50.1.0/24), Run subnet callgenie-dev-public-subnet (10.50.2.0/24).
  Check these ranges against future VPN/peering networks before connecting them.
- OS Login and Shielded VM enabled. Application VMs remain private. Only Redis
  has a public IP for startup package downloads without NAT; Redis binds only to
  localhost and its private IP, and no public Redis ingress rule is added.
- IAP API enabled; only IAP's documented 35.235.240.0/20 relay range can reach SSH/22.
  Empty IAP member lists deliberately leave user/group IAM grants to the operator.
- Redis reserves private address 10.50.1.10. Only application-tagged VMs and the
  dedicated Cloud Run subnet (10.50.2.0/24) can reach Redis TCP/6379.
  Direct VPC ingress rules cannot match Cloud Run source tags, so Run uses a
  separate subnet-based rule. No broad internal allow rule
  or public HTTP/Redis rule is created.
- Cloud NAT and its dedicated Cloud Router are disabled for dev. Cloud Run retains
  Direct VPC egress with ALL_TRAFFIC. Application VMs and Cloud Run have no general
  internet egress through NAT. Redis uses its own external IP for downloads;
  Private Google Access remains enabled on both subnets.
- Cloud SQL uses a private services access allocation, no public IPv4, and requires
  encrypted client connections.
- Cloud Run keeps an internet-reachable endpoint but requires IAM authentication:
  no allUsers invoker grant. This supersedes the workbook's public-access setting
  to match the later request for zero trust.
- Firestore uses its IAM-protected managed service endpoint, not a private VM IP.
  VPC Service Controls and organization policies are not managed in this environment.

This is an infrastructure baseline, not a complete application authentication system.
VMs explicitly disable service-account attachment. Cloud Run uses the existing
project default compute service account; that identity must exist for deployment.
No dedicated runtime service accounts or project-level role grants are created.
The deploying identity also needs Firestore create/update permissions (for example,
roles/datastore.owner); curated bootstrap deployment identities are not updated here.
The operator supplies IAP tunnel/OS Login/service-account access, Cloud Run invoker
access, and resource-scoped application IAM permissions as required.
The Redis VM installs Redis using its startup script; see [Redis setup](redis-callgenie.md).
Application VMs do not install application software. Redis client credentials and
TLS setup remain operator-managed.
No usernames, passwords, secret values, or application credentials are stored in YAML.

IAP reference: https://docs.cloud.google.com/iap/docs/using-tcp-forwarding
Direct VPC reference: https://docs.cloud.google.com/run/docs/configuring/vpc-direct-vpc

## Tags and labels

VM network tags describe firewall membership: `callgenie-dev-iap-ssh` allows
IAP SSH, `callgenie-dev-redis-client` identifies VMs allowed to connect to Redis,
and `callgenie-dev-redis-server` identifies the Redis firewall target.
Application VMs also carry `callgenie-dev-live-server` or
`callgenie-dev-application-server` to distinguish their roles.
Cloud Run reaches Redis through its subnet-based rule.

VMs, Cloud Run, the bucket, and Artifact Registry explicitly label
`application: callgenie`, `environment: dev`, `owner: devops`, and
`managed_by: terraform`. The `component` and `tier` labels identify each
resource's purpose. The framework environment key remains `callgenie`.

## Workbook details and assumptions

- Both application VMs use n2-standard-2 (2 vCPU / 8 GB), with Ubuntu 24.04 LTS
  and 100 GB / 70 GB pd-balanced boot disks. The second machine type and OS
  version were unspecified; these are explicit defaults. No snapshot schedules.
- Redis retains the workbook's e2-custom-small-1024 and Debian 12 / 10 GB
  pd-balanced disk. The workbook's "1 vCPU" description is inconsistent with this
  E2 small shared-core type, which has 0.5 sustained fractional vCPU. Review before
  deployment if one dedicated CPU is required; N1 custom-1-1024 is an alternative.
  CPU platform is left at the selected machine family's provider default.
  Reference: https://docs.cloud.google.com/compute/docs/general-purpose-machines
- SQL explicitly selects MYSQL_8_4, ENTERPRISE, db-custom-1-3840, REGIONAL HA,
  20 GB SSD with autoresize, backups, MySQL binary logs/PITR, and both Terraform
  and GCP deletion protection. Backup retention after deletion is disabled.
  Database users are omitted for manual management. Automatic minor upgrade is
  set false as requested; this is not a promise to disable managed 8.4 maintenance.
  The installed provider computes backup_tier; it cannot be set to STANDARD.
  Verify the actual backup tier in the first real plan/API response.
  References: https://docs.cloud.google.com/sql/docs/mysql/create-instance
  https://docs.cloud.google.com/sql/docs/mysql/backup-recovery/configure-pitr
- Firestore is STANDARD / FIRESTORE_NATIVE, Google-managed encryption, PITR
  disabled, and no scheduled backups. Database deletion protection is enabled.
- Artifact Registry is Standard Docker, Google-managed encryption, immutable tags
  disabled, cleanup dry run with no delete policy. Vulnerability scanning is left
  at the platform default as requested; no scanning override is created.
- Bucket versioning and deletion protection on durable managed resources follow
  the framework's defaults. Neither secret has a Terraform-managed value/version.
- The sample image us-docker.pkg.dev/cloudrun/container/hello:latest does not
  implement CallGenie or configure Redis/SQL credentials.
- Vertex AI API is enabled; no model, endpoint, or Vertex AI workload is created.
- No budget amount was provided. The current static cost catalogue lacks rates for
  the custom Redis/SQL sizes, so its estimate is incomplete.
- GitHub Actions supports Callgenie; repository environment registration and
  verified deployment identities are required before running a real plan/apply.

## Local validation and deployment (PowerShell, repository root)

The validation command reports the expected `SEC_PUBLIC_VM` error for Redis.
The render command records the approved public-IP exception in `override-audit.jsonl`;
review findings before using it. No other security exceptions are expected.

```powershell
python -m engine.cli validate config/environments/callgenie
python -m engine.cli render config/environments/callgenie --out environments/callgenie/.generated/deployment.normalized.json --force-security --reason "Approved dev Redis external IP for package downloads without NAT; private Redis bind and restricted ingress"
terraform -chdir=environments/callgenie init -backend-config="bucket=YOUR_STATE_BUCKET" -backend-config="prefix=callgenie"
terraform -chdir=environments/callgenie validate
terraform -chdir=environments/callgenie plan -out=callgenie.tfplan
```

After reviewing the real plan and setting required identities:

```powershell
terraform -chdir=environments/callgenie apply callgenie.tfplan
```

The authoring checks use Terraform mock providers and never apply to GCP.
The complete-stack test uses a simulated apply to resolve computed outputs; all
providers in that test are mocked. Module tests read the committed YAML directly.
To run the CallGenie mock test after rendering, initialize with `-backend=false`
in a fresh local working directory, then run
`terraform -chdir=environments/callgenie test`. A mock project ID is set by the test;
it does not create a project. Do not use `-backend=false` as a deployment backend.

## GitHub deployment setup

Create a GitHub Environment named `callgenie` with a required reviewer. Add a
`callgenie` entry to repository variable `ENVIRONMENTS_JSON` containing the existing
`wif_provider`, `tf_plan_sa`, `tf_apply_sa`, `state_bucket`, and `artifact_bucket`.
Use identities with verified access to `prj-dg-cl-apps-dev` and the state/artifact
buckets. Disabling runtime service accounts does not remove the need for CI
identities to authenticate Terraform. Do not store service-account keys in Git.

Both workflows support manual selection of `callgenie`. Their validation helper
allows only `SEC_PUBLIC_VM` on `vm.dg-cg-redis-vm` for Callgenie and records the
existing security-override audit. Other validation errors still block deployment.
Startup script and environment Terraform changes also trigger environment detection.

Push a feature branch, open a PR, review the Terraform plan, and merge only when
the configured environment and identities are ready. Shared infrastructure changes
trigger multiple environment jobs, so inspect all affected plans before merging.
After merge, approve only the intended GitHub Environment deployment. Run Redis
startup checks from [Redis setup](redis-callgenie.md) after deployment; Terraform
completion does not establish application readiness.
