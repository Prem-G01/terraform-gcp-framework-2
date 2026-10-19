"""Dependency engine.

Two independent checks:

1. Type-level: for every ENABLED resource type, every type it `requires`
   (config/global/dependencies.yaml) must also be enabled. Also detects
   cycles in the graph itself (a config-integrity check, not deployment
   specific — a cycle would make dependency order undecidable for every
   deployment, so it's checked once regardless of which environment you're
   validating).

2. Instance-level: cross-references between resource instances (e.g.
   vm.app-vm-01.subnet: "app-subnet") must point at an instance that
   actually exists in the target type's `instances` map.
"""

from __future__ import annotations

from typing import Any

from engine.errors import Finding

# (field path on the source instance, target resource type it must name an
# instance of). Only checked when the source type is enabled.
INSTANCE_REFERENCES: dict[str, list[tuple[str, str]]] = {
    "subnet": [("vpc", "vpc")],
    "firewall": [("network", "vpc")],
    "router": [("network", "vpc")],
    "nat": [("router", "router")],
    "private_service_access": [("network", "vpc")],
    "vm": [("subnet", "subnet"), ("service_account.name", "service_accounts")],
    "cloudsql": [("network.private_network", "vpc")],
    "cloudrun": [
        ("service_account.name", "service_accounts"),
        ("vpc_access.network", "vpc"),
        ("vpc_access.subnet", "subnet"),
    ],
    "load_balancer": [("backend.service", "cloudrun")],
    "workflows": [("service_account", "service_accounts")],
    "gke": [("network", "vpc"), ("subnet", "subnet"), ("node_pool.service_account", "service_accounts")],
    "cloudfunctions": [("service_account.name", "service_accounts")],
    "memorystore": [("network", "vpc")],
    "iap": [("target_vm", "vm")],
    "workload_identity": [("gcp_service_account", "service_accounts")],
}


def _get_path(obj: dict, dotted: str) -> Any:
    node = obj
    for part in dotted.split("."):
        if not isinstance(node, dict) or part not in node:
            return None
        node = node[part]
    return node


def validate_dependency_graph_integrity(global_config) -> list[Finding]:
    """Detects cycles in config/global/dependencies.yaml itself."""
    graph = {k: v.get("requires", []) for k, v in (global_config.dependencies.get("dependencies") or {}).items()}
    findings: list[Finding] = []
    WHITE, GRAY, BLACK = 0, 1, 2
    color = {node: WHITE for node in graph}

    def visit(node: str, path: list[str]) -> bool:
        color[node] = GRAY
        for dep in graph.get(node, []):
            if dep not in graph:
                continue
            if color.get(dep, WHITE) == GRAY:
                cycle = " -> ".join(path + [node, dep])
                findings.append(
                    Finding(
                        severity="ERROR",
                        category="dependency",
                        rule="DEPENDENCY_CYCLE",
                        resource="config/global/dependencies.yaml",
                        message=f"Circular dependency detected: {cycle}",
                    )
                )
                return True
            if color.get(dep, WHITE) == WHITE and visit(dep, path + [node]):
                return True
        color[node] = BLACK
        return False

    for node in list(graph):
        if color[node] == WHITE:
            visit(node, [])
    return findings


def validate_type_dependencies(deployment) -> list[Finding]:
    graph = deployment.global_config.dependencies.get("dependencies") or {}
    enabled = set(deployment.enabled_resource_types())
    findings: list[Finding] = []

    for rtype in sorted(enabled):
        requires = graph.get(rtype, {}).get("requires", [])
        missing = [dep for dep in requires if dep not in enabled]
        if missing:
            findings.append(
                Finding(
                    severity="ERROR",
                    category="dependency",
                    rule=f"{rtype.upper()}_DEPENDENCY_MISSING",
                    resource=rtype,
                    message=(
                        f"'{rtype}' requires {', '.join(requires)} to be enabled, "
                        f"but {', '.join(missing)} is not."
                    ),
                    missing=[f"resources.{d}.enabled: true" for d in missing],
                )
            )
    return findings


def _check_reference(deployment, enabled, source_resource, field_path, value, target_type, findings):
    if target_type not in enabled:
        findings.append(
            Finding(
                severity="ERROR",
                category="dependency",
                rule="REFERENCED_RESOURCE_TYPE_DISABLED",
                resource=source_resource,
                message=(
                    f"{field_path} = '{value}' references a {target_type} instance, "
                    f"but resources.{target_type}.enabled is false."
                ),
            )
        )
        return
    target_instances = deployment.instances(target_type)
    if value not in target_instances:
        findings.append(
            Finding(
                severity="ERROR",
                category="dependency",
                rule="INVALID_REFERENCE",
                resource=source_resource,
                message=(
                    f"{field_path} = '{value}' does not match any instance under "
                    f"resources.{target_type}.instances ({', '.join(sorted(target_instances)) or 'none defined'})."
                ),
            )
        )


# (source resource type, nested collection field, field on each collection
# entry that references an instance, target type it must name an instance
# of). Separate from INSTANCE_REFERENCES because these references live
# inside a per-instance nested map (e.g. cloudsql.<instance>.users.<user>
# .password_secret), not directly on the instance itself — a single
# dotted path can't express "for every entry in this nested map, check
# this field."
NESTED_INSTANCE_REFERENCES: list[tuple[str, str, str, str]] = [
    ("cloudsql", "users", "password_secret", "secrets"),
    ("pubsub", "subscriptions", "dead_letter_policy.topic", "pubsub"),
]


def validate_instance_references(deployment) -> list[Finding]:
    findings: list[Finding] = []
    enabled = set(deployment.enabled_resource_types())

    for rtype, refs in INSTANCE_REFERENCES.items():
        if rtype not in enabled:
            continue
        for name, instance in deployment.instances(rtype).items():
            for field_path, target_type in refs:
                value = _get_path(instance, field_path)
                if value in (None, ""):
                    continue  # required-field check in schema_validator handles absence
                _check_reference(deployment, enabled, f"{rtype}.{name}", field_path, value, target_type, findings)

    # Direct VPC needs a subnet in the selected network and service region.
    services = deployment.instances("cloudrun") if "cloudrun" in enabled else {}
    for name, service in services.items():
        access = service.get("vpc_access")
        if not isinstance(access, dict):
            continue
        subnet = deployment.instances("subnet").get(access.get("subnet"), {})
        if not subnet:
            continue
        for field, actual, expected in (
            ("vpc", subnet.get("vpc"), access.get("network")),
            ("region", subnet.get("region"), service.get("location")),
        ):
            if actual and expected and actual != expected:
                findings.append(Finding(
                    severity="ERROR",
                    category="dependency",
                    rule="CLOUDRUN_VPC_MISMATCH",
                    resource=f"cloudrun.{name}",
                    message=f"VPC access subnet {field} is '{actual}', expected '{expected}'.",
                ))

    for rtype, collection_field, ref_field, target_type in NESTED_INSTANCE_REFERENCES:
        if rtype not in enabled:
            continue
        for name, instance in deployment.instances(rtype).items():
            collection = instance.get(collection_field) if isinstance(instance, dict) else None
            if not isinstance(collection, dict):
                continue
            for entry_key, entry in collection.items():
                if not isinstance(entry, dict):
                    continue
                value = _get_path(entry, ref_field)
                if value in (None, ""):
                    continue
                _check_reference(
                    deployment,
                    enabled,
                    f"{rtype}.{name}.{collection_field}.{entry_key}",
                    ref_field,
                    value,
                    target_type,
                    findings,
                )

    return findings
