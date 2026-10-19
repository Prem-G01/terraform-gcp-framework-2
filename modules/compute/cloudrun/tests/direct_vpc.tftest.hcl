mock_provider "google" {}
variables {
  project_id       = "callgenie-test-project"
  service_accounts = {}
  vpcs = {
    callgenie-dev-vpc = "projects/callgenie-test-project/global/networks/callgenie-dev-vpc"
  }
  subnets = {
    callgenie-dev-public-subnet = "projects/callgenie-test-project/regions/asia-south1/subnetworks/callgenie-dev-public-subnet"
  }
  config = {
    cloudrun = yamldecode(replace(file("../../../config/environments/callgenie/deployment.yaml"), "{region}", "asia-south1")).resources.cloudrun.instances
  }
}
run "authenticated_service_uses_dedicated_private_subnet" {
  command = plan
  assert {
    condition     = google_cloud_run_v2_service.cloudrun["dg-api-backend-cl"].template[0].vpc_access[0].egress == "ALL_TRAFFIC"
    error_message = "Cloud Run traffic must follow the configured VPC egress path."
  }
  assert {
    condition     = google_cloud_run_v2_service.cloudrun["dg-api-backend-cl"].template[0].vpc_access[0].network_interfaces[0].subnetwork == var.subnets["callgenie-dev-public-subnet"]
    error_message = "The service must attach the selected Run subnet."
  }
  assert {
    condition     = google_cloud_run_v2_service.cloudrun["dg-api-backend-cl"].template[0].vpc_access[0].network_interfaces[0].network == var.vpcs["callgenie-dev-vpc"]
    error_message = "The service must use the configured private VPC."
  }
  assert {
    condition     = length(google_cloud_run_v2_service_iam_member.public_invoker) == 0
    error_message = "The private access baseline must not grant allUsers invoker."
  }
}
