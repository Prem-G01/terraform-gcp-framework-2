resource "google_monitoring_metric_descriptor" "metrics" {
  for_each     = var.config.metric_descriptors
  project      = var.project_id
  type         = each.value.type
  metric_kind  = each.value.metric_kind
  value_type   = each.value.value_type
  unit         = lookup(each.value, "unit", "1")
  display_name = lookup(each.value, "display_name", each.key)
  description  = each.value.description
}
