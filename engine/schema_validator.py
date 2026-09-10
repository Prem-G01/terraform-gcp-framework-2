"""YAML + JSON Schema + per-resource required-field validation.

Three layers, cheapest first:
  1. YAML syntax        -> engine.config_loader raises ConfigError
  2. JSON Schema         -> config/schema/deployment.schema.json (envelope,
                            known resource types, enabled/instances shape)
  3. Required fields     -> RESOURCE_RULES below (the fields Terraform will
                            hard-fail on with a much less readable error if
                            they're missing, e.g. a VM with no subnet)
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import jsonschema

from engine.errors import Finding

# Dotted paths required on every instance of a resource type. A path like
# "service_account.name" means instance["service_account"]["name"] must be
# present and non-empty.
RESOURCE_RULES: dict[str, dict] = {
    "vpc": {"required": ["auto_create_subnetworks", "routing_mode"]},
    "subnet": {"required": ["vpc", "region", "cidr"]},
    "firewall": {"required": ["network", "direction"]},
    "router": {"required": ["region", "network", "bgp.asn"]},
    "nat": {"required": ["region", "router"]},
    "private_service_access": {"required": ["network", "address.name", "service"]},
    "service_accounts": {"required": ["account_id"]},
    "vm": {"required": ["zone", "machine_type", "subnet", "service_account.name", "boot_disk.image"]},
    "secrets": {"required": ["secret_id", "length"]},
    "cloudsql": {"required": ["region", "database_version", "tier", "network.private_network"]},
    "buckets": {"required": ["location", "storage_class"]},
    "artifact_registry": {"required": ["repository_id", "format", "location"]},
    "kms": {"required": ["location", "keys"]},
    "pubsub": {"required": ["topic.name"]},
    "cloudtasks": {"required": ["location"]},
    "cloudrun": {"required": ["location", "image.repository", "image.path", "image.tag"]},
    "load_balancer": {"required": ["region", "backend.type", "backend.service"]},
    "scheduler": {"required": ["location", "schedule", "http_target.uri"]},
    "workflows": {"required": ["region", "service_account", "source_contents"]},
    "notification_channels": {"required": ["type"]},
    "alert_policies": {"required": ["filter", "threshold", "comparison"]},
    "uptime_checks": {"required": ["host", "path"]},
    "logging": {"required": ["bucket_id", "location"]},
    "bigquery": {"required": ["location"]},
    "documentai": {"required": ["location", "type"]},
    "gke": {"required": ["location", "network", "subnet", "node_pool.machine_type", "node_pool.service_account", "private_cluster.master_ipv4_cidr_block"]},
    "cloudfunctions": {"required": ["location", "runtime", "entry_point", "source.bucket", "source.object", "service_account.name"]},
    "memorystore": {"required": ["region", "memory_size_gb", "network"]},
    "vpc_service_controls": {"required": ["restricted_services"]},
    # Found 2026-08-25: iap/workload_identity had no RESOURCE_RULES entry
    # at all, and both modules access these fields directly with no
    # lookup()/try() fallback (modules/security/iap/main.tf's
    # `cfg.target_vm`/`cfg.members`;
    # modules/security/workload_identity/main.tf's
    # `each.value.gcp_service_account`/`.k8s_namespace`/
    # `.k8s_service_account`) — an omitted field would have crashed
    # `terraform plan` with a raw "Unsupported attribute" error instead of
    # a clean validation message. `members: []` (present, empty) is a
    # deliberate, valid state — see docs/security.md "Identity-Aware
    # Proxy" — and still passes this check; only an entirely absent
    # `members` key is now caught.
    "iap": {"required": ["target_vm", "members"]},
    "workload_identity": {"required": ["gcp_service_account", "k8s_namespace", "k8s_service_account"]},
}

_RULE_ID = {
    "vm": "VM_NETWORK_REQUIRED",
    "subnet": "SUBNET_NETWORK_REQUIRED",
    "firewall": "FIREWALL_NETWORK_REQUIRED",
    "cloudsql": "CLOUDSQL_NETWORK_REQUIRED",
    "cloudrun": "CLOUDRUN_IMAGE_REQUIRED",
    "gke": "GKE_NETWORK_REQUIRED",
    "cloudfunctions": "CLOUDFUNCTION_SOURCE_REQUIRED",
    "memorystore": "MEMORYSTORE_NETWORK_REQUIRED",
}


def _get_path(obj: dict, dotted: str) -> Any:
    node = obj
    for part in dotted.split("."):
        if not isinstance(node, dict) or part not in node:
            return None
        node = node[part]
    return node


def load_schema(config_root: Path) -> dict:
    schema_path = Path(config_root) / "schema" / "deployment.schema.json"
    with schema_path.open("r", encoding="utf-8") as fh:
        return json.load(fh)


def validate_schema(raw_deployment: dict, config_root: Path) -> list[Finding]:
    schema = load_schema(config_root)
    validator = jsonschema.Draft7Validator(schema)
    findings: list[Finding] = []
    for err in sorted(validator.iter_errors(raw_deployment), key=lambda e: list(e.path)):
        location = ".".join(str(p) for p in err.path) or "<root>"
        findings.append(
            Finding(
                severity="ERROR",
                category="schema",
                rule="SCHEMA_VIOLATION",
                resource=location,
                message=err.message,
            )
        )
    return findings


def validate_required_fields(deployment) -> list[Finding]:
    findings: list[Finding] = []
    for rtype in deployment.enabled_resource_types():
        rules = RESOURCE_RULES.get(rtype)
        if not rules:
            continue
        for name, instance in deployment.instances(rtype).items():
            missing = [p for p in rules["required"] if _get_path(instance, p) in (None, "")]
            if missing:
                findings.append(
                    Finding(
                        severity="ERROR",
                        category="schema",
                        rule=_RULE_ID.get(rtype, f"{rtype.upper()}_REQUIRED_FIELDS"),
                        resource=f"{rtype}.{name}",
                        message=f"Required field(s) missing for resource type '{rtype}'.",
                        missing=missing,
                    )
                )
    return findings
