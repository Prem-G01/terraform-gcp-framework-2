# Deploying `saafe` into `prj-dg-api-prod-shared`

`saafe` is a **spoke environment**: its Terraform identities live in the
hub project `prj-dg-devops-test`; its actual resources (1 bucket, 2
secrets, 1 Cloud Run service, 1 service account) are created in
`prj-dg-api-prod-shared`. Logs from `prj-dg-api-prod-shared` are exported
to a dedicated GCS bucket in the hub project.

```
GitHub: Prem-G01/terraform-gcp-framework-2
        │  plan.yml (PR)  /  apply.yml (merge to main, gated by reviewers)
        ▼   authenticates via WIF, no SA keys
prj-dg-devops-test  (hub)
  ├─ prj-dg-devops-test-tfstate-v5        state, prefix=saafe
  ├─ prj-dg-devops-test-tf-artifacts-v5   plan.json / apply_outputs.json
  ├─ prj-dg-devops-test-tf-logs-v5        centralized log export
  ├─ tf-plan-saafe@…  (roles/viewer, securityReviewer)
  └─ tf-apply-saafe@… (curated *.admin list — granted IN the spoke)
        │  impersonated via WIF
        ▼
prj-dg-api-prod-shared  (spoke)
  ├─ dg-api-saafe                (bucket, asia-south1)
  ├─ dg-api-token-private-key-saafe, dg-api-mysql-connection-saafe (secrets)
  ├─ cloudrun-service-account
  ├─ dg-api-backend-saafe        (Cloud Run, private — authenticated invokers only)
  └─ central-log-export-saafe    (log sink -> prj-dg-devops-test-tf-logs-v5)
```

Everything below is run **by a human**; this framework's CI never runs
bootstrap or grants. Nothing here has been applied yet.

---

## Prerequisites (access)

| Where | Who needs it | Roles |
|---|---|---|
| `prj-dg-devops-test` | operator running `bootstrap/` | `roles/owner`, or: `serviceusage.serviceUsageAdmin`, `storage.admin`, `iam.serviceAccountAdmin`, `resourcemanager.projectIamAdmin`, `iam.workloadIdentityPoolAdmin`, `logging.configWriter` |
| `prj-dg-api-prod-shared` | operator running `bootstrap/grants/` | `resourcemanager.projectIamAdmin`, `serviceusage.serviceUsageAdmin`, `logging.configWriter` |
| GitHub repo | repo admin | create Environment `saafe`; set repo variable `ENVIRONMENTS_JSON` |

`bootstrap/grants/` grants `tf-apply-saafe@prj-dg-devops-test…` the full
curated `apply_sa_roles` list (`modules/iam/deploy_roles`) inside
`prj-dg-api-prod-shared` — ~27 predefined `*.admin` roles. Approved
2026-09-09.

---

## Step 1 — Push the repo to GitHub

The existing `origin` points at the old `terraform-gcp-framework` repo, and
the `saafe` environment plus several framework files are still uncommitted.
Repoint and push everything:

```bash
git remote set-url origin https://github.com/Prem-G01/terraform-gcp-framework-2.git
git add -A
git commit -m "Wire saafe -> prj-dg-api-prod-shared (spoke), bootstrap v5 buckets"
git push -u origin main
```

## Step 2 — Apply `bootstrap/` (hub), first pass

From Cloud Shell (has your creds + terraform) or a workstation with
`gcloud auth application-default login` against `prj-dg-devops-test`:

```bash
cd bootstrap
cp terraform.tfvars.example terraform.tfvars      # values already filled in
terraform init
terraform apply                                   # review the plan, then yes
```

Record the outputs:

```bash
terraform output                     # state_bucket, artifact_bucket, log_bucket
terraform output -raw workload_identity_provider
terraform output terraform_plan_sa_emails
terraform output terraform_apply_sa_emails
```

Expected: `state_bucket = prj-dg-devops-test-tfstate-v5`,
`artifact_bucket = prj-dg-devops-test-tf-artifacts-v5`,
`log_bucket = prj-dg-devops-test-tf-logs-v5`,
`workload_identity_provider = projects/<PRJ_NUM>/locations/global/workloadIdentityPools/cicd-pool/providers/github`.

## Step 3 — Apply `bootstrap/grants/` against the spoke

`gcloud config set project prj-dg-api-prod-shared` (or use `--project`),
then:

```bash
cd ../bootstrap/grants
cp saafe.tfvars.example saafe.tfvars
terraform init
terraform apply -var-file=saafe.tfvars            # review, then yes
terraform output -raw log_sink_writer_identity    # copy this
```

## Step 4 — Apply `bootstrap/` again, wiring centralized logging

Paste the writer identity from Step 3 into `bootstrap/terraform.tfvars`:

```hcl
log_sink_writer_identities = {
  saafe = "serviceAccount:service-<PRJ_NUM>@gcp-sa-logging.iam.gserviceaccount.com"
}
```

```bash
cd ../../bootstrap
terraform apply     # only adds 1 bucket IAM binding
```

## Step 5 — GitHub configuration (web UI)

**Settings → Environments → New environment → `saafe`** — add the required
reviewer(s) who must approve every `saafe` apply.

**Settings → Secrets and variables → Actions → Variables → `ENVIRONMENTS_JSON`**
— add (or merge) the `saafe` key. `<PRJ_NUM>` is the hub project number
from Step 2:

```json
{
  "saafe": {
    "wif_provider": "projects/<PRJ_NUM>/locations/global/workloadIdentityPools/cicd-pool/providers/github",
    "tf_plan_sa": "tf-plan-saafe@prj-dg-devops-test.iam.gserviceaccount.com",
    "tf_apply_sa": "tf-apply-saafe@prj-dg-devops-test.iam.gserviceaccount.com",
    "state_bucket": "prj-dg-devops-test-tfstate-v5",
    "artifact_bucket": "prj-dg-devops-test-tf-artifacts-v5"
  }
}
```

## Step 6 — Deploy saafe

- **PR** touching `config/environments/saafe/**` → `plan.yml` runs as
  `tf-plan-saafe`, posts the plan. Review it.
- **Merge to main** → `apply.yml` pauses on the `saafe` GitHub Environment
  for reviewer approval, then applies as `tf-apply-saafe`.
- Or run **Actions → Terraform Apply → Run workflow → environment: saafe**
  manually.

The first apply deploys the placeholder Cloud Run image
(`us-docker.pkg.dev/cloudrun/container/hello`, publicly pullable) — enough
to prove the pipeline end to end.

## Step 7 — Post-apply

```bash
# Real secret values (module only seeds a random placeholder version)
printf '%s' "<real private key>"       | gcloud secrets versions add dg-api-token-private-key-saafe --project prj-dg-api-prod-shared --data-file=-
printf '%s' "<real mysql conn string>" | gcloud secrets versions add dg-api-mysql-connection-saafe  --project prj-dg-api-prod-shared --data-file=-
```

Then swap the real `dg-api-backend` image into
`config/environments/saafe/deployment.yaml` `cloudrun.….image` and grant
the `prj-dg-api-prod-shared` Cloud Run service agent
`roles/artifactregistry.reader` on the registry project if the image
lives elsewhere. PR → review → merge to redeploy.

---

## Local `plan` (read-only, optional)

```bash
cd environments/saafe
terraform init \
  -backend-config="bucket=prj-dg-devops-test-tfstate-v5" \
  -backend-config="prefix=saafe"
python -m engine.cli render config/environments/saafe \
  --out environments/saafe/.generated/deployment.normalized.json
terraform plan
```

## Teardown notes

`dg-api-backend-saafe` (Cloud Run) and both secrets have
`deletion_protection: true` — a `terraform destroy` fails until that's
flipped to `false` in `deployment.yaml` and re-applied. The three hub
buckets are `force_destroy = false` — empty them before destroying
`bootstrap/`.
