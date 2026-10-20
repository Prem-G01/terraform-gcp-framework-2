"""CallGenie configuration and private-network reference validation."""
from copy import deepcopy

import pytest

from conftest import CONFIG_ROOT
from engine import config_loader, dependency_engine, schema_validator, security_engine, region_engine
from engine.cli import run_validation


def load():
    return config_loader.load_deployment(CONFIG_ROOT / "environments" / "callgenie", CONFIG_ROOT)


def test_callgenie_requires_only_the_approved_redis_public_ip_exception():
    report = run_validation(CONFIG_ROOT / "environments" / "callgenie")
    assert [(f.rule, f.resource) for f in report.errors] == [("SEC_PUBLIC_VM", "vm.dg-cg-redis-vm")], report.render()


def test_callgenie_private_baseline_and_monitoring_only_vm_identity():
    deployment = load()
    assert [(f.rule, f.resource) for f in security_engine.validate_security(deployment)] == [("SEC_PUBLIC_VM", "vm.dg-cg-redis-vm")]
    assert not deployment.normalized["resources"]["service_accounts"]["enabled"]
    assert "service_account" not in deployment.instances("cloudrun")["dg-api-backend-cl"]
    vms = deployment.instances("vm")
    assert all(vm["service_account"]["enabled"] is True for vm in vms.values())
    assert {vm["service_account"]["email"] for vm in vms.values()} == {"callgenie-monitoring@prj-dg-cl-apps-dev.iam.gserviceaccount.com"}
    assert all(vm["allow_stopping_for_update"] is True for vm in vms.values())
    assert set(vms) == {"dg-lk-server-vm", "dg-cl-vm", "dg-cg-redis-vm"}
    assert all(not vm["network"]["public_ip"] for name, vm in vms.items() if name != "dg-cg-redis-vm")
    assert vms["dg-cg-redis-vm"]["network"]["public_ip"] is True
    assert vms["dg-cg-redis-vm"]["network"]["internal_ip"] == "10.50.1.10"
    assert all(not iap["members"] for iap in deployment.instances("iap").values())
    service = deployment.instances("cloudrun")["dg-api-backend-cl"]
    assert service["allow_unauthenticated"] is False
    assert service["vpc_access"]["egress"] == "ALL_TRAFFIC"
    assert all(not secret["manage_version"] for secret in deployment.instances("secrets").values())


@pytest.mark.parametrize("field", ["network", "subnet"])
def test_misspelled_direct_vpc_reference_is_rejected(field):
    deployment = deepcopy(load())
    deployment.normalized["resources"]["cloudrun"]["instances"]["dg-api-backend-cl"]["vpc_access"][field] = "missing-reference"
    findings = dependency_engine.validate_instance_references(deployment)
    assert any(f.rule == "INVALID_REFERENCE" for f in findings)


@pytest.mark.parametrize("field", ["network", "subnet"])
def test_incomplete_direct_vpc_configuration_is_rejected(field):
    deployment = deepcopy(load())
    del deployment.normalized["resources"]["cloudrun"]["instances"]["dg-api-backend-cl"]["vpc_access"][field]
    findings = schema_validator.validate_required_fields(deployment)
    assert any("vpc_access." + field in f.missing for f in findings)


@pytest.mark.parametrize(("field", "value"), [("vpc", "another-vpc"), ("region", "us-central1")])
def test_direct_vpc_subnet_must_match_service_network_and_region(field, value):
    deployment = deepcopy(load())
    deployment.normalized["resources"]["subnet"]["instances"]["callgenie-dev-public-subnet"][field] = value
    findings = dependency_engine.validate_instance_references(deployment)
    assert any(f.rule == "CLOUDRUN_VPC_MISMATCH" for f in findings)


def test_firestore_location_is_validated_before_terraform():
    deployment = deepcopy(load())
    deployment.normalized["resources"]["firestore"]["instances"]["default-db"]["location"] = "unapproved-region"
    assert any(f.rule == "REGION_NOT_APPROVED" for f in region_engine.validate_regions(deployment))


def test_redis_ingress_allows_cloud_run_subnet_without_public_exposure():
    from ipaddress import ip_network
    deployment = load()
    run_subnet = deployment.instances("subnet")["callgenie-dev-public-subnet"]
    redis_rules = [
        rule for rule in deployment.instances("firewall").values()
        if "callgenie-dev-redis-server" in rule.get("target_tags", [])
    ]
    assert any(
        ip_network(run_subnet["cidr"]).subnet_of(ip_network(source))
        for rule in redis_rules for source in rule.get("source_ranges", [])
    )
    assert all(
        ip_network(source).is_private
        for rule in redis_rules for source in rule.get("source_ranges", [])
    )
    assert all(
        entry["protocol"] == "tcp" and entry["ports"] == ["6379"]
        for rule in redis_rules for entry in rule["allow"]
    )


def test_monitoring_uses_verified_metric_units_and_keeps_idle_services_healthy():
    deployment = load()
    policies = deployment.instances("alert_policies")
    assert policies["vm-memory-high"]["threshold"] == 85
    assert policies["vm-cpu-high"]["threshold"] == 0.8
    assert policies["redis-memory_utilization"]["threshold"] == 0.8
    assert policies["run-p95-latency"]["threshold"] == 1000
    assert policies["firestore-p95-latency"]["threshold"] == 1
    assert all(
        policy.get("condition_type") != "absence"
        for policy in policies.values()
        if 'cloud_run_revision' in policy["filter"] or 'firestore.googleapis.com/Database' in policy["filter"]
    )
    assert deployment.instances("notification_channels")["callgenie-operations-email"]["address"] == "premkumar.gunasekaran@docugenieai.com"


def test_redis_metric_descriptors_match_the_collector_contract():
    from scripts.monitoring.redis_metrics import METRIC_DEFINITIONS, METRIC_PREFIX
    descriptors = load().instances("metric_descriptors")
    assert set(descriptors) == set(METRIC_DEFINITIONS)
    for key, definition in METRIC_DEFINITIONS.items():
        descriptor = descriptors[key]
        assert descriptor["type"] == METRIC_PREFIX + key
        assert descriptor["unit"] == definition["unit"]
        assert descriptor["value_type"] == "DOUBLE" and descriptor["metric_kind"] == "GAUGE"
