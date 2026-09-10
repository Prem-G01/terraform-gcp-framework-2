# manage_version: false (per instance) => Terraform creates only the empty
# secret container; the caller adds the real value out of band
# (`gcloud secrets versions add ...`). Default true keeps the historical
# behaviour: a generated random placeholder version so the secret is never
# empty after apply.
locals {
  managed_version_secrets = {
    for k, v in var.config.secrets : k => v
    if lookup(v, "manage_version", true)
  }
}

resource "random_password" "passwords" {
  for_each = local.managed_version_secrets
  length   = each.value.length
  special  = each.value.special
}

resource "google_secret_manager_secret" "secrets" {
  for_each  = var.config.secrets
  project   = var.project_id
  secret_id = each.value.secret_id
  replication {
    auto {}
  }

  # Defaults to GCP's own native default (false) rather than this
  # platform's usual true-by-default for cloudsql/gke/bigquery/
  # workflows/cloudrun — a generated secret (see random_password.passwords
  # above) is trivially regeneratable, not durable state. Opt in
  # per-instance for a secret whose value genuinely can't be
  # regenerated (e.g. one holding externally-issued credentials).
  deletion_protection = lookup(each.value, "deletion_protection", false)
}

resource "google_secret_manager_secret_version" "versions" {
  for_each = local.managed_version_secrets
  secret = google_secret_manager_secret.secrets[
    each.key
  ].id

  secret_data = random_password.passwords[
    each.key
  ].result

}