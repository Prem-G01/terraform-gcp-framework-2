mock_provider "google" {}
variables {
  project_id = "callgenie-test-project"
  vpcs = {
    callgenie-dev-vpc = "projects/callgenie-test-project/global/networks/callgenie-dev-vpc"
  }
  passwords = {}
  config = {
    cloudsql = yamldecode(replace(file("../../../config/environments/callgenie/deployment.yaml"), "{region}", "asia-south1")).resources.cloudsql.instances
  }
}
run "mysql_84_has_private_ha_recovery_and_encrypted_connections" {
  command = plan
  assert {
    condition     = google_sql_database_instance.cloudsql["dg-api-csql"].database_version == "MYSQL_8_4" && google_sql_database_instance.cloudsql["dg-api-csql"].settings[0].edition == "ENTERPRISE"
    error_message = "MySQL 8.4 must explicitly use the requested Enterprise edition."
  }
  assert {
    condition     = google_sql_database_instance.cloudsql["dg-api-csql"].settings[0].tier == "db-custom-1-3840" && google_sql_database_instance.cloudsql["dg-api-csql"].settings[0].availability_type == "REGIONAL"
    error_message = "The requested SQL shape and HA must reach the provider."
  }
  assert {
    condition     = google_sql_database_instance.cloudsql["dg-api-csql"].settings[0].backup_configuration[0].binary_log_enabled == true
    error_message = "MySQL recovery requires binary logs, not the PostgreSQL PITR flag."
  }
  assert {
    condition     = !google_sql_database_instance.cloudsql["dg-api-csql"].settings[0].ip_configuration[0].ipv4_enabled && google_sql_database_instance.cloudsql["dg-api-csql"].settings[0].ip_configuration[0].ssl_mode == "ENCRYPTED_ONLY"
    error_message = "SQL must have no public IPv4 and must require encrypted clients."
  }
  assert {
    condition     = google_sql_database_instance.cloudsql["dg-api-csql"].deletion_protection && google_sql_database_instance.cloudsql["dg-api-csql"].settings[0].deletion_protection_enabled
    error_message = "Both Terraform and GCP deletion protections must be enabled."
  }
  assert {
    condition     = google_sql_database_instance.cloudsql["dg-api-csql"].settings[0].retain_backups_on_delete == false
    error_message = "Backup retention after instance deletion must remain disabled per the workbook."
  }
  assert {
    condition     = length(google_sql_user.users) == 0
    error_message = "SQL usernames and passwords are managed manually."
  }
}
