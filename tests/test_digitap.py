"""Digitap deployment and Cloud Run job integration checks."""
from copy import deepcopy
import pytest
from conftest import CONFIG_ROOT
from engine.cli import run_validation
from engine import config_loader, dependency_engine, schema_validator


def load():
    return config_loader.load_deployment(CONFIG_ROOT / "environments" / "digitap", CONFIG_ROOT)


def test_digitap_passes_validation_without_security_overrides():
    report = run_validation(CONFIG_ROOT / "environments" / "digitap")
    assert not report.errors, report.render()


def test_redis_is_private_and_only_run_subnet_can_reach_it():
    deployment = load()
    vm = deployment.instances("vm")["dg-api-digitap-redis"]
    assert vm["network"] == {"public_ip": False, "internal_ip": "10.60.1.10"}
    rules = [r for r in deployment.instances("firewall").values() if "digitap-redis" in r.get("target_tags", [])]
    assert len(rules) == 1
    assert rules[0]["source_ranges"] == ["10.60.2.0/24"]
    assert rules[0]["allow"] == [{"protocol": "tcp", "ports": ["6379"]}]
    assert deployment.resources["nat"]["enabled"]


@pytest.mark.parametrize("field", ["image", "timeout", "task_count", "parallelism", "max_retries"])
def test_incomplete_job_is_rejected(field):
    deployment = deepcopy(load())
    del deployment.instances("cloudrun_jobs")["dg-api-digitap-bsa-job"][field]
    findings = schema_validator.validate_required_fields(deployment)
    assert any(f.resource == "cloudrun_jobs.dg-api-digitap-bsa-job" and field in f.missing for f in findings)


@pytest.mark.parametrize("field", ["network", "subnet"])
def test_job_vpc_typo_is_rejected(field):
    deployment = deepcopy(load())
    deployment.instances("cloudrun_jobs")["dg-api-digitap-bsa-job"]["vpc_access"][field] = "missing-reference"
    assert any(f.rule == "INVALID_REFERENCE" for f in dependency_engine.validate_instance_references(deployment))


def test_job_vpc_region_mismatch_is_rejected():
    deployment = deepcopy(load())
    deployment.instances("cloudrun_jobs")["dg-api-digitap-bsa-job"]["location"] = "us-central1"
    assert any(f.rule == "CLOUDRUN_VPC_MISMATCH" and f.resource.startswith("cloudrun_jobs.") for f in dependency_engine.validate_instance_references(deployment))


def test_default_workflow_identity_and_no_managed_secret_value():
    deployment = load()
    assert not schema_validator.validate_required_fields(deployment)
    assert deployment.instances("workflows")["dg-api-digitap-bsa-processing"]["use_default_service_account"] is True
    assert not deployment.instances("secrets")["dg-api-digitap-mysql-connection"]["manage_version"]
