"""Naming validation — config/global/naming.yaml against project id,
environment, and resource instance keys (the instance key becomes the GCP
resource name unless an instance explicitly overrides it, see modules/*
`lookup(each.value, "name", each.key)`)."""

from __future__ import annotations

import re

from engine.errors import Finding

_ALLOWED_ENVIRONMENTS = {"dev", "sit", "uat", "prod", "saafe"}


def validate_naming(deployment) -> list[Finding]:
    naming = deployment.global_config.naming.get("naming", {})
    max_len = naming.get("max_length", {})
    allowed_chars = naming.get("allowed_characters", {})
    default_pattern = allowed_chars.get("default", "^[a-z][a-z0-9-]*[a-z0-9]$")
    # Resource types whose GCP naming rules genuinely differ from the
    # default compute-style pattern (e.g. BigQuery datasets allow
    # underscores and mixed case; buckets allow dots).
    TYPE_PATTERN_KEY = {"bigquery": "bigquery_dataset", "buckets": "bucket"}
    # Same idea for max_length — config/global/naming.yaml defines
    # sql_instance (98) and bigquery_dataset (1024) explicitly higher than
    # compute's 63, but every resource type was being checked against a
    # single hardcoded compute_max regardless of its own declared limit —
    # found 2026-08-24, same class of gap as region_engine.py's
    # zone_suffixes (a config value that looked enforced but wasn't). A
    # real BigQuery dataset name between 64 and 1024 characters — valid
    # per both GCP and this platform's own config — would have been
    # wrongly rejected as NAME_TOO_LONG.
    TYPE_MAX_LENGTH_KEY = {"bigquery": "bigquery_dataset", "buckets": "bucket", "cloudsql": "sql_instance"}
    findings: list[Finding] = []

    project_id = deployment.raw.get("project", {}).get("id", "")
    project_max = max_len.get("project_id", 30)
    if len(project_id) > project_max:
        findings.append(
            Finding(
                severity="ERROR",
                category="naming",
                rule="PROJECT_ID_TOO_LONG",
                resource="project.id",
                message=f"'{project_id}' is {len(project_id)} characters; the limit is {project_max}.",
            )
        )

    environment = deployment.environment
    if environment not in _ALLOWED_ENVIRONMENTS:
        findings.append(
            Finding(
                severity="ERROR",
                category="naming",
                rule="ENVIRONMENT_NAME_INVALID",
                resource="metadata.environment",
                message=f"'{environment}' is not one of {sorted(_ALLOWED_ENVIRONMENTS)}.",
            )
        )

    default_max = max_len.get("compute", max_len.get("default", 63))
    reserved = set(naming.get("reserved_words", []))

    for rtype in deployment.enabled_resource_types():
        pattern = allowed_chars.get(TYPE_PATTERN_KEY.get(rtype, ""), default_pattern)
        type_max = max_len.get(TYPE_MAX_LENGTH_KEY.get(rtype, ""), default_max)
        for name, instance in deployment.instances(rtype).items():
            resource_name = instance.get("name", name) if isinstance(instance, dict) else name
            if not isinstance(resource_name, str):
                continue
            if resource_name in reserved:
                findings.append(
                    Finding(
                        severity="ERROR",
                        category="naming",
                        rule="RESERVED_NAME",
                        resource=f"{rtype}.{name}",
                        message=f"'{resource_name}' is a reserved word (config/global/naming.yaml).",
                    )
                )
            if not re.match(pattern, resource_name):
                findings.append(
                    Finding(
                        severity="WARNING",
                        category="naming",
                        rule="NAME_PATTERN_MISMATCH",
                        resource=f"{rtype}.{name}",
                        message=f"'{resource_name}' does not match the naming pattern {pattern}.",
                    )
                )
            if len(resource_name) > type_max:
                findings.append(
                    Finding(
                        severity="ERROR",
                        category="naming",
                        rule="NAME_TOO_LONG",
                        resource=f"{rtype}.{name}",
                        message=f"'{resource_name}' is {len(resource_name)} characters; the limit is {type_max}.",
                    )
                )

    return findings
