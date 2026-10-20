mock_provider "google" {}

variables {
  project_id = "monitoring-test-project"
  config = {
    dashboards = {
      overview = {
        dashboard = {
          displayName = "Environment Overview"
          mosaicLayout = {
            columns = 12
            tiles = [{
              width  = 12
              height = 3
              widget = { title = "Operations", text = { content = "Runbook", format = "MARKDOWN" } }
            }]
          }
        }
      }
    }
  }
}

run "dashboard_json_keeps_layout_and_widgets" {
  command = plan
  assert {
    condition     = jsondecode(google_monitoring_dashboard.dashboards["overview"].dashboard_json).displayName == "Environment Overview" && jsondecode(google_monitoring_dashboard.dashboards["overview"].dashboard_json).mosaicLayout.tiles[0].widget.text.content == "Runbook"
    error_message = "The dashboard API JSON must preserve the configured title, layout, and widgets."
  }
  assert {
    condition     = contains(keys(output.dashboards), "overview")
    error_message = "Dashboard IDs must be exposed by configuration key."
  }
}
