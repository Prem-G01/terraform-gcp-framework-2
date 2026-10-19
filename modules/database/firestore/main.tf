resource "google_firestore_database" "database" {
  for_each = var.config.firestore

  project          = var.project_id
  name             = each.value.database_id
  location_id      = each.value.location
  type             = lookup(each.value, "type", "FIRESTORE_NATIVE")
  database_edition = lookup(each.value, "database_edition", "STANDARD")

  point_in_time_recovery_enablement = lookup(
    each.value, "point_in_time_recovery_enablement", "POINT_IN_TIME_RECOVERY_DISABLED",
  )
  delete_protection_state = lookup(each.value, "delete_protection_state", "DELETE_PROTECTION_DISABLED")
  deletion_policy         = lookup(each.value, "deletion_policy", "ABANDON")
}
