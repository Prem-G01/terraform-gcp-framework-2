# Render the CallGenie config before running this offline mock simulation.
mock_provider "google" {
  mock_resource "google_compute_network" {
    defaults = {
      self_link = "projects/callgenie-test-project/global/networks/callgenie-dev-vpc"
    }
  }
  mock_resource "google_compute_subnetwork" {
    defaults = {
      self_link = "projects/callgenie-test-project/regions/asia-south1/subnetworks/mock-subnet"
    }
  }
  mock_resource "google_service_account" {
    defaults = {
      email = "runtime@callgenie-test-project.iam.gserviceaccount.com"
    }
  }
}
mock_provider "random" {}

run "complete_callgenie_stack_simulates_without_cloud_access" {
  command = apply
  variables {
    project_id = "callgenie-test-project"
  }

  assert {
    condition     = length(output.enabled_resources) == 13
    error_message = "The requested services and supporting infrastructure must all be enabled."
  }
  assert {
    condition     = length(output.vm_internal_ips) == 3 && output.vm_internal_ips["dg-cg-redis-vm"] == "10.50.1.10"
    error_message = "Three VMs must be planned, with the reserved Redis private IP attached."
  }
  assert {
    condition     = length(output.iap_bindings) == 0
    error_message = "Human access grants must remain manual."
  }
  assert {
    condition     = length(output.firestore_database_ids) == 1
    error_message = "The Firestore database must be included in the actual Terraform graph."
  }
  assert {
    condition     = length(output.service_account_emails) == 0
    error_message = "No dedicated runtime service accounts should be created."
  }
}
