resource "google_monitoring_dashboard" "dashboards" {
  for_each = var.config.dashboards

  project        = var.project_id
  dashboard_json = jsonencode(each.value.dashboard)
}
