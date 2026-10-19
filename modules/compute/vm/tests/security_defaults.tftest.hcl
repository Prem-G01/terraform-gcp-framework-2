# Regression test for the real gap a security_defaults audit found
# (2026-08-19, see docs/security.md): network.public_ip and all three
# shielded_vm.* fields were hard-required each.value.field references
# with zero fallback — safe only because every real environment's
# config happened to set them explicitly.
#
# Run: cd modules/compute/vm && terraform test

mock_provider "google" {}

variables {
  project_id       = "prj-dg-devops-test"
  subnets          = { "app-subnet" = "projects/prj-dg-devops-test/regions/asia-south1/subnetworks/app-subnet" }
  service_accounts = { "vm-sa" = "vm-sa@prj-dg-devops-test.iam.gserviceaccount.com" }
}

run "omitted_security_fields_fall_back_to_secure_defaults" {
  command = plan

  variables {
    config = {
      vms = {
        app-vm-01 = {
          zone         = "asia-south1-a"
          machine_type = "e2-medium"
          subnet       = "app-subnet"
          service_account = {
            name   = "vm-sa"
            scopes = ["cloud-platform"]
          }
          boot_disk = {
            image   = "projects/debian-cloud/global/images/family/debian-12"
            size_gb = 50
            type    = "pd-balanced"
          }
          # network and shielded_vm are deliberately omitted here.
          metadata = {}
          tags     = []
          labels   = {}
        }
      }
    }
  }

  assert {
    condition     = length(google_compute_address.internal) == 0 && length(google_compute_instance.vm["app-vm-01"].network_interface[0].access_config) == 0
    error_message = "network.public_ip must default to false (no access_config block) when omitted from config"
  }

  assert {
    condition     = google_compute_instance.vm["app-vm-01"].shielded_instance_config[0].enable_secure_boot == true
    error_message = "shielded_vm.secure_boot must default to true when omitted from config"
  }

  assert {
    condition     = google_compute_instance.vm["app-vm-01"].shielded_instance_config[0].enable_vtpm == true
    error_message = "shielded_vm.vtpm must default to true when omitted from config"
  }

  assert {
    condition     = google_compute_instance.vm["app-vm-01"].shielded_instance_config[0].enable_integrity_monitoring == true
    error_message = "shielded_vm.integrity_monitoring must default to true when omitted from config"
  }
}

run "explicit_public_ip_is_never_overridden" {
  command = plan

  variables {
    config = {
      vms = {
        app-vm-01 = {
          zone         = "asia-south1-a"
          machine_type = "e2-medium"
          subnet       = "app-subnet"
          service_account = {
            name   = "vm-sa"
            scopes = ["cloud-platform"]
          }
          boot_disk = {
            image   = "projects/debian-cloud/global/images/family/debian-12"
            size_gb = 50
            type    = "pd-balanced"
          }
          network  = { public_ip = true }
          metadata = {}
          tags     = []
          labels   = {}
        }
      }
    }
  }

  assert {
    condition     = length(google_compute_instance.vm["app-vm-01"].network_interface[0].access_config) == 1
    error_message = "an explicit network.public_ip = true must never be silently overridden to false"
  }
}
