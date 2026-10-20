"""Required-field validation for metric monitoring and existing VM identities."""
from engine import schema_validator


class Deployment:
    def __init__(self, resource_type, instance):
        self.resource_type = resource_type
        self.instance = instance

    def enabled_resource_types(self):
        return [self.resource_type]

    def instances(self, resource_type):
        return {"example": self.instance} if resource_type == self.resource_type else {}


def missing(resource_type, instance):
    return {field for finding in schema_validator.validate_required_fields(
        Deployment(resource_type, instance)
    ) for field in finding.missing}


def test_absence_requires_filter_and_duration_without_threshold_fields():
    assert missing("alert_policies", {"condition_type": "absence", "filter": "metric", "duration": "600s"}) == set()
    assert missing("alert_policies", {"condition_type": "absence", "filter": "metric"}) == {"duration"}


def test_threshold_keeps_comparison_and_threshold_required():
    assert missing("alert_policies", {"filter": "metric"}) == {"threshold", "comparison"}


def test_dashboard_and_metric_descriptor_required_fields():
    assert missing("dashboards", {}) == {"dashboard"}
    assert missing("metric_descriptors", {}) == {"type", "metric_kind", "value_type", "description"}


def test_existing_vm_service_account_email_does_not_require_a_created_account_name():
    instance = {
        "zone": "asia-south1-a", "machine_type": "e2-small", "subnet": "private",
        "boot_disk": {"image": "debian-12"},
        "service_account": {"enabled": True, "email": "monitoring@example-project.iam.gserviceaccount.com"},
    }
    assert missing("vm", instance) == set()
    instance["service_account"] = {"enabled": True}
    assert missing("vm", instance) == {"service_account.name"}
