terraform {
  required_version = ">= 1.9.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.37"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }

  # Bucket name is deliberately absent — every value here would be a
  # hardcode violation for a config that differs per environment. Supplied
  # at `terraform init` time via -backend-config, generated from
  # bootstrap's outputs (see docs/state-management.md and
  # scripts create no state of their own, only reference it):
  #
  #   terraform init \
  #     -backend-config="bucket=<state bucket from bootstrap output>" \
  #     -backend-config="prefix=saafe"
  backend "gcs" {}
}
