resource "google_sql_database_instance" "cloudsql" {

  for_each = var.config.cloudsql

  project = var.project_id

  name = lookup(each.value, "name", lookup(var.generated_names, each.key, each.key))

  region = each.value.region

  database_version = each.value.database_version

  # Defaults to true, matching engine/security_engine.py's
  # SEC_SQL_NO_DELETION_PROTECTION check (`sql.get("deletion_protection",
  # True)`) — that check only flags an *explicit* `false`, so an omitted
  # field must resolve the same way here or a config that passes
  # validation cleanly could still crash `terraform plan` with a raw
  # "Unsupported attribute" error. Found 2026-08-24: docs/security.md
  # already documented this lookup() as done; the code never actually
  # had it.
  deletion_protection = lookup(each.value, "deletion_protection", true)



  settings {

    edition                     = try(each.value.edition, null)
    auto_upgrade_enabled        = try(each.value.auto_upgrade_enabled, null)
    retain_backups_on_delete    = try(each.value.retain_backups_on_delete, null)
    deletion_protection_enabled = try(each.value.deletion_protection_enabled, null)

    tier = each.value.tier

    availability_type = each.value.availability_type



    disk_size = each.value.disk.size

    disk_type = each.value.disk.type

    disk_autoresize = each.value.disk.autoresize



    backup_configuration {
      # MySQL PITR uses binary logs; the PostgreSQL PITR flag is separate.
      binary_log_enabled             = try(each.value.backup.binary_log_enabled, null)
      transaction_log_retention_days = try(each.value.backup.transaction_log_retention_days, null)


      # `backup` was, like deletion_protection above, a hard-required
      # each.value reference with no fallback and no schema/engine-level
      # guarantee it's set (config/schema/deployment.schema.json only
      # validates the generic resourceBlock shape, not per-resource
      # internals) — same gap class as the 2026-08-19 security_defaults
      # audit, found auditing modules the CI/CD-focused review hadn't
      # reached yet (2026-08-24). Defaults match every real environment's
      # actual config value.
      enabled = lookup(lookup(each.value, "backup", {}), "enabled", true)

      start_time = lookup(lookup(each.value, "backup", {}), "start_time", "00:00")

    }



    ip_configuration {
      ssl_mode = try(each.value.network.ssl_mode, null)


      # Secure-by-default fallback matching
      # security_defaults.database.public_ip (false) — this platform's
      # own copy of that value, not a live reference to
      # security_defaults.yaml (see docs/security.md). Found missing
      # entirely while auditing for the same class of gap as the
      # deletion_protection fix in modules/compute/cloudrun.
      ipv4_enabled = try(each.value.network.ipv4_enabled, false)

      private_network = var.vpcs[

        each.value.network.private_network

      ]

    }



    insights_config {

      query_insights_enabled = each.value.insights.query_insights_enabled

      query_string_length = each.value.insights.query_string_length

      record_application_tags = each.value.insights.record_application_tags

      record_client_address = each.value.insights.record_client_address

    }

  }

}


locals {

  sql_users = flatten([

    for instance_name, instance in var.config.cloudsql : [

      for user_name, user in lookup(instance, "users", {}) : {

        instance_name = instance_name

        username = user.username

        secret_name = user.password_secret

        host = lookup(user, "host", "%")

      }

    ]

  ])

  sql_users_map = {
    for u in local.sql_users :
    "${u.instance_name}-${u.username}" => u
  }

}

resource "google_sql_user" "users" {

  for_each = local.sql_users_map

  project  = var.project_id
  instance = google_sql_database_instance.cloudsql[each.value.instance_name].name

  name     = each.value.username
  host     = each.value.host
  password = var.passwords[each.value.secret_name]
}
