output "dashboards" {
  description = "Cloud Monitoring dashboard IDs by configuration key."
  value       = { for key, dashboard in google_monitoring_dashboard.dashboards : key => dashboard.id }
}
