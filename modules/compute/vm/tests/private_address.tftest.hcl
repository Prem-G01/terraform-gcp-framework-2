mock_provider "google" {}
variables {
  project_id = "callgenie-test-project"
  subnets = {
    callgenie-dev-private-subnet = "projects/callgenie-test-project/regions/asia-south1/subnetworks/callgenie-dev-private-subnet"
  }
  service_accounts = {}
  config = {
    vms = yamldecode(replace(file("../../../config/environments/callgenie/deployment.yaml"), "{region}", "asia-south1")).resources.vm.instances
  }
}
run "redis_bootstrap_has_outbound_access_and_reserved_private_address" {
  command = plan
  assert {
    condition     = google_compute_instance.vm["dg-cg-redis-vm"].metadata["startup-script"] == replace(file("../../../scripts/startup/redis.sh"), "\r\n", "\n")
    error_message = "The Redis startup script must be attached as inline VM metadata."
  }
  assert {
    condition     = alltrue([for key, vm in google_compute_instance.vm : !contains(keys(vm.metadata), "startup-script") if key != "dg-cg-redis-vm"])
    error_message = "Redis installation must only run on the Redis VM."
  }
  assert {
    condition     = alltrue([for vm in google_compute_instance.vm : length(vm.service_account) == 1 && vm.service_account[0].email == "callgenie-monitoring@prj-dg-cl-apps-dev.iam.gserviceaccount.com"])
    error_message = "CallGenie VMs must attach only the approved monitoring identity."
  }
  assert {
    condition     = length(google_compute_address.internal) == 1
    error_message = "Only the Redis VM should request an address reservation."
  }
  assert {
    condition     = google_compute_address.internal["dg-cg-redis-vm"].address == "10.50.1.10" && google_compute_address.internal["dg-cg-redis-vm"].address_type == "INTERNAL"
    error_message = "Redis must reserve the requested internal address."
  }
  assert {
    condition     = google_compute_address.internal["dg-cg-redis-vm"].region == "asia-south1"
    error_message = "The reserved address must be in the VM region."
  }
  assert {
    condition     = google_compute_instance.vm["dg-cg-redis-vm"].network_interface[0].network_ip == "10.50.1.10"
    error_message = "The reservation must be attached to Redis, not merely created."
  }
  assert {
    condition     = alltrue([for key, vm in google_compute_instance.vm : length(vm.network_interface[0].access_config) == (key == "dg-cg-redis-vm" ? 1 : 0)])
    error_message = "Only the Redis VM may have an external access_config for package downloads."
  }
}
