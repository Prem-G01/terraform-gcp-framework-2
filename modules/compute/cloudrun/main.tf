resource "google_cloud_run_v2_service" "cloudrun" {
  for_each            = var.config.cloudrun
  project             = var.project_id
  name                = lookup(each.value, "name", each.key)
  location            = each.value.location
  ingress             = each.value.ingress
  deletion_protection = lookup(each.value, "deletion_protection", true)
  labels              = each.value.labels

  # `ingress` above only controls which *network paths* can reach this
  # service (INGRESS_TRAFFIC_ALL still lets a fronting load_balancer or
  # a direct request in) — it does NOT grant IAM authorization. Cloud Run
  # requires an explicit invoker binding regardless, or every request
  # gets 403 even through a public load balancer built specifically to
  # expose this service. Found 2026-08-25 by actually curling a real
  # deployed service + its load_balancer (both returned 403) rather than
  # just checking `terraform apply` succeeded — this module had no way
  # to grant public invoker access at all before this.

  template {
    # Optional. If service_account.name names a platform-created SA, use its
    # email; else service_account.email is taken verbatim (an SA that already
    # exists in the target project); else null — Cloud Run then runs as the
    # project's default compute service account.
    service_account = try(
      var.service_accounts[each.value.service_account.name],
      each.value.service_account.email,
      null,
    )

    # All three optional — nil (Terraform's `null`) leaves the provider's
    # own default in place, so existing configs that don't set these are
    # unaffected. concurrency: max_instance_request_concurrency (default
    # 80). timeout: max request duration, e.g. "300s" (default "300s").
    # execution_environment: EXECUTION_ENVIRONMENT_GEN1 (default) or
    # _GEN2.
    max_instance_request_concurrency = lookup(each.value, "concurrency", null)
    timeout                          = lookup(each.value, "timeout", null)
    execution_environment            = lookup(each.value, "execution_environment", null)

    scaling {
      min_instance_count = each.value.scaling.min_instance_count
      max_instance_count = each.value.scaling.max_instance_count
    }

    containers {
      image = format(
        "%s/%s:%s",
        each.value.image.repository,
        each.value.image.path,
        each.value.image.tag
      )

      resources {
        limits = {
          cpu    = each.value.resources.cpu
          memory = each.value.resources.memory
        }
        # cpu_idle true (default) = CPU allocated only while handling a
        # request ("Request-based" billing in the console); false =
        # always allocated ("Instance-based"). startup_cpu_boost false
        # is the provider default.
        cpu_idle          = lookup(each.value.resources, "cpu_idle", null)
        startup_cpu_boost = lookup(each.value.resources, "startup_cpu_boost", null)
      }
      dynamic "env" {

        for_each = each.value.env
        content {
          name  = env.key
          value = env.value
        }
      }
    }
  }
}

# Deny-by-default: omitting allow_unauthenticated (or setting it false)
# means only IAM-authorized callers can invoke this service, matching
# this platform's usual secure-by-default posture. Set
# allow_unauthenticated: true explicitly when a service is genuinely
# meant to be reachable without credentials (e.g. one fronted by a
# public load_balancer, like this platform's own app-api/app-lb pair).
resource "google_cloud_run_v2_service_iam_member" "public_invoker" {
  for_each = { for k, v in var.config.cloudrun : k => v if lookup(v, "allow_unauthenticated", false) }

  project  = var.project_id
  location = each.value.location
  name     = google_cloud_run_v2_service.cloudrun[each.key].name
  role     = "roles/run.invoker"
  member   = "allUsers"
}