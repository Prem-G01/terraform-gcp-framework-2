provider "google" {
  project = var.project_id
  region  = var.region

  # Required for APIs like Org Policy to bill/quota against the right
  # project when running as a human's Application Default Credentials
  # (gcloud auth application-default login) rather than a service
  # account. ADC's own quota_project_id field alone isn't enough — a
  # human running this without these two lines hits "Error 403: ...
  # requires a quota project" against Google's own shared gcloud-CLI
  # OAuth client project (764086051850), not var.project_id, even after
  # `gcloud auth application-default set-quota-project`. Found running a
  # real apply — see docs/troubleshooting.md.
  user_project_override = true
  billing_project       = var.project_id
}
