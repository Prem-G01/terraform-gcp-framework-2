# Creating a job does not execute it. No execution resource or trigger is created.
resource "google_cloud_run_v2_job" "job" {
  for_each            = var.config.jobs
  project             = var.project_id
  name                = lookup(each.value, "name", each.key)
  location            = each.value.location
  labels              = each.value.labels
  deletion_protection = lookup(each.value, "deletion_protection", true)

  template {
    task_count  = each.value.task_count
    parallelism = each.value.parallelism
    template {
      timeout     = each.value.timeout
      max_retries = each.value.max_retries
      service_account = try(
        var.service_accounts[each.value.service_account.name],
        each.value.service_account.email,
        null,
      )
      containers {
        image   = each.value.image
        command = lookup(each.value, "command", null)
        args    = lookup(each.value, "args", null)
        resources {
          limits = {
            cpu    = each.value.resources.cpu
            memory = each.value.resources.memory
          }
        }
        dynamic "env" {
          for_each = lookup(each.value, "env", {})
          content {
            name  = env.key
            value = env.value
          }
        }
      }
      dynamic "vpc_access" {
        for_each = try(each.value.vpc_access, null) == null ? [] : [each.value.vpc_access]
        content {
          egress = lookup(vpc_access.value, "egress", "PRIVATE_RANGES_ONLY")
          network_interfaces {
            network    = replace(var.vpcs[vpc_access.value.network], "/^https:\\/\\/[^/]+\\/compute\\/v1\\//", "")
            subnetwork = replace(var.subnets[vpc_access.value.subnet], "/^https:\\/\\/[^/]+\\/compute\\/v1\\//", "")
            tags       = lookup(vpc_access.value, "tags", [])
          }
        }
      }
    }
  }
}
