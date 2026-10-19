"""CI must allow only the approved Redis exception and fail closed otherwise."""
import pytest
from engine.ci_prepare import unapproved_errors
from engine.errors import Finding, ValidationReport


def report(*findings):
    result = ValidationReport()
    result.extend(list(findings))
    return result


def finding(rule="SEC_PUBLIC_VM", resource="vm.dg-cg-redis-vm", category="security"):
    return Finding("ERROR", category, rule, resource, "test")


def test_approved_redis_exception_is_scoped_to_callgenie():
    approved = finding()
    assert unapproved_errors("callgenie", report(approved)) == []
    assert unapproved_errors("prod", report(approved)) == [approved]


@pytest.mark.parametrize("error", [
    finding(resource="vm.dg-cl-vm"),
    finding(rule="SEC_PUBLIC_SSH", resource="firewall.ssh"),
    finding(category="schema"),
])
def test_additional_errors_cannot_be_forced(error):
    assert unapproved_errors("callgenie", report(finding(), error)) == [error]
