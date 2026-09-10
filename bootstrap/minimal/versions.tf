terraform {
  required_version = ">= 1.9.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.37"
    }
  }

  # Local backend: this stack CREATES the state bucket every other stack
  # uses, so it can't store its own state there. Run once, by a human.
  # The resulting terraform.tfstate.minimal is not sensitive (bucket names
  # + a log-sink writer identity, no keys) but still keep it with the repo
  # operator, not in git (*.tfstate* is gitignored).
  backend "local" {
    path = "terraform.tfstate.minimal"
  }
}
