locals {
  channel_keys = {
    for key, policy in var.config.alert_policies : key => (
      try(policy.notification_channels, null) == null
      ? keys(var.notification_channels)
      : policy.notification_channels
    )
  }
  selected_channels = {
    for key, channel_keys in local.channel_keys : key => [
      for channel in channel_keys : var.notification_channels[channel]
      if contains(keys(var.notification_channels), channel)
    ]
  }
}

resource "google_monitoring_alert_policy" "alerts" {
  for_each = var.config.alert_policies

  project               = var.project_id
  display_name          = each.value.display_name
  combiner              = "OR"
  enabled               = try(each.value.enabled, true)
  severity              = try(each.value.severity, null)
  user_labels           = try(each.value.user_labels, null)
  notification_channels = local.selected_channels[each.key]

  conditions {
    display_name = each.value.display_name

    dynamic "condition_threshold" {
      for_each = try(each.value.condition_type, "threshold") == "threshold" ? [each.value] : []
      content {
        filter                  = trimspace(condition_threshold.value.filter)
        duration                = condition_threshold.value.duration
        comparison              = condition_threshold.value.comparison
        threshold_value         = condition_threshold.value.threshold
        denominator_filter      = try(trimspace(condition_threshold.value.denominator_filter), null)
        evaluation_missing_data = try(condition_threshold.value.evaluation_missing_data, null)

        aggregations {
          alignment_period     = try(condition_threshold.value.alignment_period, "60s")
          per_series_aligner   = try(condition_threshold.value.aligner, "ALIGN_MEAN")
          cross_series_reducer = try(condition_threshold.value.cross_series_reducer, null)
          group_by_fields      = try(condition_threshold.value.group_by_fields, null)
        }

        dynamic "denominator_aggregations" {
          for_each = try(trimspace(condition_threshold.value.denominator_filter), "") != "" ? [condition_threshold.value] : []
          content {
            # Ratios require matching alignment and grouping on both sides.
            alignment_period     = try(denominator_aggregations.value.alignment_period, "60s")
            per_series_aligner   = try(denominator_aggregations.value.aligner, "ALIGN_MEAN")
            cross_series_reducer = try(denominator_aggregations.value.cross_series_reducer, null)
            group_by_fields      = try(denominator_aggregations.value.group_by_fields, null)
          }
        }

        dynamic "trigger" {
          for_each = try(condition_threshold.value.trigger_count, null) == null ? [] : [condition_threshold.value.trigger_count]
          content {
            count = trigger.value
          }
        }
      }
    }

    dynamic "condition_absent" {
      for_each = try(each.value.condition_type, "threshold") == "absence" ? [each.value] : []
      content {
        filter   = trimspace(condition_absent.value.filter)
        duration = condition_absent.value.duration
      }
    }
  }

  dynamic "documentation" {
    for_each = try(each.value.documentation, null) == null ? [] : [each.value.documentation]
    content {
      content   = documentation.value
      mime_type = "text/markdown"
    }
  }

  dynamic "alert_strategy" {
    for_each = try(each.value.alert_strategy, null) == null ? [] : [each.value.alert_strategy]
    content {
      auto_close           = try(alert_strategy.value.auto_close, null)
      notification_prompts = try(alert_strategy.value.notification_prompts, null)

      dynamic "notification_channel_strategy" {
        for_each = try(alert_strategy.value.renotify_interval, null) != null && length(local.selected_channels[each.key]) > 0 ? [alert_strategy.value.renotify_interval] : []
        content {
          notification_channel_names = local.selected_channels[each.key]
          renotify_interval          = notification_channel_strategy.value
        }
      }
    }
  }

  lifecycle {
    precondition {
      condition     = contains(["threshold", "absence"], try(each.value.condition_type, "threshold"))
      error_message = "Alert condition_type must be threshold or absence."
    }
    precondition {
      condition     = alltrue([for channel in local.channel_keys[each.key] : contains(keys(var.notification_channels), channel)])
      error_message = "Every selected notification_channels key must exist in the notification channel map."
    }
  }
}
