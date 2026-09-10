# Two providers: the default one targets the hub project (buckets); the
# aliased "logsource" one targets whichever project's logs are exported
# (var.log_source_project_id, default = the spoke project). Both run as the
# human operator's Application Default Credentials — there is no deploy
# service account in this model.

provider "google" {
  project = var.hub_project_id
  region  = var.region

  # Needed when running as a human's ADC rather than a service account —
  # see environments/dev/provider.tf for the full explanation.
  user_project_override = true
  billing_project       = var.hub_project_id
}

provider "google" {
  alias   = "logsource"
  project = local.log_source_project_id
  region  = var.region

  user_project_override = true
  billing_project       = local.log_source_project_id
}
