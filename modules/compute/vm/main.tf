# Reserve an internal address only when the deployment requests one.
resource "google_compute_address" "internal" {
  for_each = {
    for key, vm in var.config.vms : key => vm
    if try(vm.network.internal_ip, null) != null
  }

  project      = var.project_id
  name         = lookup(each.value, "name", lookup(var.generated_names, each.key, each.key))
  region       = regex("^(.*)-[a-z]$", each.value.zone)[0]
  address_type = "INTERNAL"
  purpose      = "GCE_ENDPOINT"
  subnetwork   = var.subnets[each.value.subnet]
  address      = each.value.network.internal_ip
}

resource "google_compute_instance" "vm" {
  for_each     = var.config.vms
  project      = var.project_id
  name         = lookup(each.value, "name", lookup(var.generated_names, each.key, each.key))
  zone         = each.value.zone
  machine_type = each.value.machine_type
  tags         = each.value.tags
  labels       = each.value.labels
  # startup_script_file is relative to this framework's repository root.
  # Metadata updates do not force VM replacement; rerun the guest script to apply.
  metadata = merge(
    each.value.metadata,
    try(each.value.startup_script_file, null) == null ? {} : {
      "startup-script" = replace(file("${path.module}/../../../${each.value.startup_script_file}"), "\r\n", "\n")
    },
  )

  boot_disk {
    initialize_params {
      image = each.value.boot_disk.image
      size  = each.value.boot_disk.size_gb
      type  = each.value.boot_disk.type
    }
  }

  network_interface {
    network_ip = try(google_compute_address.internal[each.key].address, null)
    subnetwork = var.subnets[
      each.value.subnet
    ]

    # Secure-by-default fallback matching config/global/defaults.yaml
    # security_defaults.compute.public_ip (false) — this platform's own
    # copy of that value, not a live reference (no module reads
    # security_defaults.yaml directly; see docs/security.md). Found
    # missing entirely while auditing for the same class of gap as the
    # deletion_protection fix in modules/compute/cloudrun.
    dynamic "access_config" {
      for_each = try(each.value.network.public_ip, false) ? [1] : []
      content {}
    }
  }

  # Explicit opt-out leaves the VM without an attached service account.
  dynamic "service_account" {
    for_each = try(each.value.service_account.enabled, true) ? [each.value.service_account] : []
    content {
      email  = var.service_accounts[service_account.value.name]
      scopes = service_account.value.scopes
    }
  }

  # Secure-by-default fallbacks matching
  # security_defaults.compute.shielded_vm (all true) — same reasoning as
  # network.public_ip above.
  shielded_instance_config {
    enable_secure_boot          = try(each.value.shielded_vm.secure_boot, true)
    enable_vtpm                 = try(each.value.shielded_vm.vtpm, true)
    enable_integrity_monitoring = try(each.value.shielded_vm.integrity_monitoring, true)
  }

  # Defaults to GCP's own native default (false), not this platform's
  # usual true-by-default for managed data stores (cloudsql/gke/bigquery/
  # workflows/cloudrun) — a machine_type or boot_disk.image change forces
  # google_compute_instance to be replaced, and deletion_protection=true
  # would block that routine, non-destructive lifecycle operation far
  # more often than it would for a rarely-replaced database or cluster.
  # Opt in per-instance for a VM that genuinely shouldn't be casually
  # replaced.
  deletion_protection = lookup(each.value, "deletion_protection", false)

}
