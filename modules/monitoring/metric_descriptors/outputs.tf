output "metric_types" { value = { for k, v in google_monitoring_metric_descriptor.metrics : k => v.type } }
