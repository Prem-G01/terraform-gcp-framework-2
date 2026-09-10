# Deploying `saafe` into `prj-dg-api-prod-shared`

Minimal model, by explicit choice: no deploy service account, no Workload
Identity Federation, no GitHub pipeline. `terraform` is run locally by a
human against their own credentials. The hub project `prj-dg-devops-test`
holds three GCS buckets; every log line from `prj-dg-api-prod-shared` is
exported to one of them.

```
operator (premkumar.gunasekaran@docugenieai.com), local terraform
        │
        ├─ bootstrap/minimal/  ──►  prj-dg-devops-test
        │      prj-dg-devops-test-tfstate-v5      (state, prefix=saafe)
        │      prj-dg-devops-test-tf-artifacts-v5 (archived plans, manual)
        │      prj-dg-devops-test-tf-logs-v5      (log export target)
        │   + prj-dg-api-prod-shared: central-log-export-prod-shared sink ──► tf-logs-v5
        │
        └─ environments/saafe/  ──►  prj-dg-api-prod-shared
               dg-api-saafe                 (bucket)
               dg-api-token-private-key-saafe, dg-api-mysql-connection-saafe (secrets)
               cloudrun-service-account     (Cloud Run runtime identity)
               dg-api-backend-saafe         (Cloud Run, private — no allUsers)
```

The full per-environment / WIF / GitHub-Actions design still exists,
unused, in `bootstrap/`, `bootstrap/grants/`, `.github/workflows/` — see
[docs/cicd.md](cicd.md) and [docs/service-accounts.md](service-accounts.md)
if it is ever wanted.

---

## Access required (as `premkumar.gunasekaran@docugenieai.com`)

| Project | Roles |
|---|---|
| `prj-dg-devops-test` | `roles/storage.admin`, `roles/serviceusage.serviceUsageAdmin` |
| `prj-dg-api-prod-shared` | `roles/logging.configWriter`, `roles/serviceusage.serviceUsageAdmin`, `roles/storage.admin`, `roles/secretmanager.admin`, `roles/run.admin`, `roles/iam.serviceAccountAdmin`, `roles/iam.serviceAccountUser`, `roles/resourcemanager.projectIamAdmin` (or `roles/owner`) |

---

## Step 0 — Credentials

```bash
gcloud auth login
gcloud auth application-default login          # this is what terraform uses
gcloud config set project prj-dg-devops-test
```

## Step 1 — Buckets + log export

```bash
cd bootstrap/minimal
cp terraform.tfvars.example terraform.tfvars   # values already filled in
terraform init
terraform plan            # review: 3 buckets, ~3 APIs, 1 sink, 1 sink IAM
terraform apply
terraform output          # note state_bucket, log_bucket
```

## Step 2 — Render + plan saafe

```bash
cd ../../environments/saafe
python -m engine.cli render config/environments/saafe \
  --out environments/saafe/.generated/deployment.normalized.json   # run from repo root path-wise; adjust if needed
terraform init \
  -backend-config="bucket=prj-dg-devops-test-tfstate-v5" \
  -backend-config="prefix=saafe"
terraform plan
```

(`render` is also fine to run from the repo root as
`python -m engine.cli render config/environments/saafe --out environments/saafe/.generated/deployment.normalized.json`.)

## Step 3 — Apply saafe

```bash
terraform apply
```

Deploys against `prj-dg-api-prod-shared` (set in
`config/environments/saafe/deployment.yaml` `project.id` and mirrored in
`environments/saafe/variables.tf`). The placeholder Cloud Run image
(`us-docker.pkg.dev/cloudrun/container/hello`) is publicly pullable, so the
first apply completes with no Artifact Registry setup.

## Step 4 — Post-apply

```bash
# Real secret values — the module only seeds a random placeholder version
printf '%s' '<real private key>'        | gcloud secrets versions add dg-api-token-private-key-saafe --project prj-dg-api-prod-shared --data-file=-
printf '%s' '<real mysql conn string>'  | gcloud secrets versions add dg-api-mysql-connection-saafe  --project prj-dg-api-prod-shared --data-file=-
```

Then swap the real backend image into
`config/environments/saafe/deployment.yaml` (`cloudrun.instances.dg-api-backend-saafe.image`),
re-render, `terraform apply` again. If the image is in another project,
grant that project's Cloud Run service agent `roles/artifactregistry.reader`
on the registry.

## Verify logs are landing

```bash
gcloud logging sinks describe central-log-export-prod-shared --project prj-dg-api-prod-shared
gcloud storage ls gs://prj-dg-devops-test-tf-logs-v5/    # objects appear within a few minutes of activity
```

---

## Teardown notes

- `dg-api-backend-saafe` and both secrets have `deletion_protection: true`
  — flip to `false` in `deployment.yaml` and re-apply before
  `terraform destroy`.
- The three hub buckets are `force_destroy = false` — empty them first.
- Destroy order: `environments/saafe` first, then `bootstrap/minimal`.
