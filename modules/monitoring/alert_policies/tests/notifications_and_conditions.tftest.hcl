mock_provider "google" {}

variables {
  project_id = "monitoring-test-project"
  notification_channels = {
    primary = "projects/monitoring-test-project/notificationChannels/100"
    backup  = "projects/monitoring-test-project/notificationChannels/200"
  }
}

run "legacy_threshold_keeps_all_channels_and_alignment_defaults" {
  command = plan
  variables {
    config = {
      alert_policies = {
        legacy = {
          display_name = "Legacy CPU"
          filter       = " metric.type=\"compute.googleapis.com/instance/cpu/utilization\" resource.type=\"gce_instance\" "
          duration     = "300s"
          comparison   = "COMPARISON_GT"
          threshold    = 0.8
        }
      }
    }
  }
  assert {
    condition     = toset(google_monitoring_alert_policy.alerts["legacy"].notification_channels) == toset(values(var.notification_channels))
    error_message = "Policies without channel selection must keep every configured channel."
  }
  assert {
    condition     = google_monitoring_alert_policy.alerts["legacy"].conditions[0].condition_threshold[0].aggregations[0].alignment_period == "60s" && google_monitoring_alert_policy.alerts["legacy"].conditions[0].condition_threshold[0].aggregations[0].per_series_aligner == "ALIGN_MEAN"
    error_message = "Legacy policies must retain the 60-second mean alignment."
  }
  assert {
    condition     = google_monitoring_alert_policy.alerts["legacy"].combiner == "OR" && google_monitoring_alert_policy.alerts["legacy"].enabled && length(google_monitoring_alert_policy.alerts["legacy"].alert_strategy) == 0 && length(google_monitoring_alert_policy.alerts["legacy"].documentation) == 0 && length(google_monitoring_alert_policy.alerts["legacy"].conditions[0].condition_absent) == 0
    error_message = "Optional alert features must not alter existing policy behavior."
  }
}

run "ratio_matches_denominator_aggregation_and_selected_channel_reminders" {
  command = plan
  variables {
    config = {
      alert_policies = {
        ratio = {
          display_name            = "Request error ratio"
          filter                  = "metric.type=\"run.googleapis.com/request_count\" resource.type=\"cloud_run_revision\" metric.labels.response_code_class=\"5xx\""
          denominator_filter      = "metric.type=\"run.googleapis.com/request_count\" resource.type=\"cloud_run_revision\""
          duration                = "300s"
          comparison              = "COMPARISON_GT"
          threshold               = 0.05
          alignment_period        = "300s"
          aligner                 = "ALIGN_RATE"
          cross_series_reducer    = "REDUCE_SUM"
          group_by_fields         = ["resource.label.service_name"]
          trigger_count           = 1
          evaluation_missing_data = "EVALUATION_MISSING_DATA_INACTIVE"
          notification_channels   = ["primary"]
          severity                = "ERROR"
          enabled                 = false
          documentation           = "Inspect the request logs and error ratio."
          user_labels             = { environment = "test" }
          alert_strategy = {
            auto_close           = "1800s"
            renotify_interval    = "3600s"
            notification_prompts = ["OPENED", "CLOSED"]
          }
        }
      }
    }
  }
  assert {
    condition     = google_monitoring_alert_policy.alerts["ratio"].conditions[0].condition_threshold[0].aggregations == google_monitoring_alert_policy.alerts["ratio"].conditions[0].condition_threshold[0].denominator_aggregations
    error_message = "Numerator and denominator must use identical alignment/reduction/grouping."
  }
  assert {
    condition     = toset(google_monitoring_alert_policy.alerts["ratio"].notification_channels) == toset([var.notification_channels.primary]) && toset(google_monitoring_alert_policy.alerts["ratio"].alert_strategy[0].notification_channel_strategy[0].notification_channel_names) == toset([var.notification_channels.primary])
    error_message = "Both incident notifications and reminders must use only selected channels."
  }
  assert {
    condition     = google_monitoring_alert_policy.alerts["ratio"].conditions[0].condition_threshold[0].trigger[0].count == 1 && google_monitoring_alert_policy.alerts["ratio"].conditions[0].condition_threshold[0].evaluation_missing_data == "EVALUATION_MISSING_DATA_INACTIVE"
    error_message = "The requested trigger count and missing-data behavior must be respected."
  }
  assert {
    condition     = google_monitoring_alert_policy.alerts["ratio"].alert_strategy[0].auto_close == "1800s" && google_monitoring_alert_policy.alerts["ratio"].alert_strategy[0].notification_channel_strategy[0].renotify_interval == "3600s" && google_monitoring_alert_policy.alerts["ratio"].severity == "ERROR" && !google_monitoring_alert_policy.alerts["ratio"].enabled && google_monitoring_alert_policy.alerts["ratio"].documentation[0].mime_type == "text/markdown" && google_monitoring_alert_policy.alerts["ratio"].user_labels.environment == "test"
    error_message = "Explicit notification strategy and policy metadata must reach the provider."
  }
}

run "absence_uses_only_its_filter_and_duration" {
  command = plan
  variables {
    config = {
      alert_policies = {
        heartbeat = {
          display_name          = "Exporter heartbeat absent"
          condition_type        = "absence"
          filter                = "metric.type=\"custom.googleapis.com/example/heartbeat\" resource.type=\"gce_instance\""
          duration              = "600s"
          notification_channels = []
          alert_strategy        = { auto_close = "1800s", renotify_interval = "3600s" }
        }
      }
    }
  }
  assert {
    condition     = length(google_monitoring_alert_policy.alerts["heartbeat"].conditions[0].condition_threshold) == 0 && google_monitoring_alert_policy.alerts["heartbeat"].conditions[0].condition_absent[0].duration == "600s"
    error_message = "Absence policies must not require threshold/comparison fields or create threshold conditions."
  }
  assert {
    condition     = length(google_monitoring_alert_policy.alerts["heartbeat"].notification_channels) == 0 && length(google_monitoring_alert_policy.alerts["heartbeat"].alert_strategy[0].notification_channel_strategy) == 0
    error_message = "An explicit empty selection must disable channel notifications and reminders."
  }
}

run "unknown_selected_channel_fails_before_apply" {
  command = plan
  variables {
    config = {
      alert_policies = {
        invalid = {
          display_name          = "Invalid channel"
          filter                = "metric.type=\"compute.googleapis.com/instance/cpu/utilization\" resource.type=\"gce_instance\""
          duration              = "300s"
          comparison            = "COMPARISON_GT"
          threshold             = 0.8
          notification_channels = ["missing"]
        }
      }
    }
  }
  expect_failures = [google_monitoring_alert_policy.alerts]
}
