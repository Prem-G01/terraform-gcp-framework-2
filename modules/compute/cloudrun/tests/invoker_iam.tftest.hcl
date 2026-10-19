# Regression test for a real bug found 2026-08-25: this module had no
# invoker mechanism at all. `ingress` only controls network reachability,
# not IAM authorization — a service left at the (secure, correct) default
# of no explicit invoker binding returned 403 to every caller, including
# through a load_balancer built specifically to expose it. Found by
# actually curling a real deployed service (and its load_balancer), not
# by checking `terraform apply` succeeded. This module had no test
# coverage at all before this.
#
# Run: cd modules/compute/cloudrun && terraform test

mock_provider "google" {}

variables {
  project_id       = "prj-dg-devops-test"
  service_accounts = { "app-service-account" = "app-service-account@prj-dg-devops-test.iam.gserviceaccount.com" }
}

run "omitted_allow_unauthenticated_grants_no_public_invoker" {
  command = plan

  variables {
    config = {
      cloudrun = {
        app-api = {
          location        = "asia-south1"
          ingress         = "INGRESS_TRAFFIC_ALL"
          labels          = {}
          service_account = { name = "app-service-account" }
          scaling         = { min_instance_count = 0, max_instance_count = 3 }
          image = {
            repository = "asia-south1-docker.pkg.dev/prj-dg-devops-test/app-repo"
            path       = "app-api"
            tag        = "latest"
          }
          resources = { cpu = "1", memory = "512Mi" }
          env       = {}
          # allow_unauthenticated is deliberately omitted here.
        }
      }
    }
  }

  assert {
    condition     = length(google_cloud_run_v2_service_iam_member.public_invoker) == 0 && length(google_cloud_run_v2_service.cloudrun["app-api"].template[0].vpc_access) == 0
    error_message = "Omitting allow_unauthenticated must grant zero public invoker bindings — deny-by-default"
  }
}

run "explicit_allow_unauthenticated_grants_public_invoker" {
  command = plan

  variables {
    config = {
      cloudrun = {
        app-api = {
          location              = "asia-south1"
          ingress               = "INGRESS_TRAFFIC_ALL"
          labels                = {}
          allow_unauthenticated = true
          service_account       = { name = "app-service-account" }
          scaling               = { min_instance_count = 0, max_instance_count = 3 }
          image = {
            repository = "asia-south1-docker.pkg.dev/prj-dg-devops-test/app-repo"
            path       = "app-api"
            tag        = "latest"
          }
          resources = { cpu = "1", memory = "512Mi" }
          env       = {}
        }
      }
    }
  }

  assert {
    condition     = google_cloud_run_v2_service_iam_member.public_invoker["app-api"].role == "roles/run.invoker"
    error_message = "allow_unauthenticated = true must grant roles/run.invoker"
  }

  assert {
    condition     = google_cloud_run_v2_service_iam_member.public_invoker["app-api"].member == "allUsers"
    error_message = "allow_unauthenticated = true must grant the invoker role to allUsers specifically, not a narrower principal"
  }
}
