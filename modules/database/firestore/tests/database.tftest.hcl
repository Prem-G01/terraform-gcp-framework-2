mock_provider "google" {}
variables {
  project_id = "callgenie-test-project"
  config = {
    firestore = yamldecode(replace(file("../../../config/environments/callgenie/deployment.yaml"), "{region}", "asia-south1")).resources.firestore.instances
  }
}
run "default_database_is_standard_native_without_pitr_or_cmek" {
  command = plan
  assert {
    condition     = google_firestore_database.database["default-db"].name == "(default)" && google_firestore_database.database["default-db"].location_id == "asia-south1"
    error_message = "The requested default database must be created in Mumbai."
  }
  assert {
    condition     = google_firestore_database.database["default-db"].type == "FIRESTORE_NATIVE" && google_firestore_database.database["default-db"].database_edition == "STANDARD"
    error_message = "The requested Firestore mode and edition must be respected."
  }
  assert {
    condition     = google_firestore_database.database["default-db"].point_in_time_recovery_enablement == "POINT_IN_TIME_RECOVERY_DISABLED" && length(google_firestore_database.database["default-db"].cmek_config) == 0
    error_message = "Firestore PITR must be off and encryption Google-managed."
  }
}
