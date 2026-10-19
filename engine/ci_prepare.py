"""Validate and render CI input with only the approved Redis public-IP exception."""
from __future__ import annotations

import argparse
from contextlib import redirect_stdout
from pathlib import Path

from engine.cli import cmd_render, cmd_validate, run_validation

REASON = "Approved Callgenie dev Redis external IP for package downloads without NAT; private Redis bind and restricted ingress"


def unapproved_errors(environment, report):
    return [
        finding for finding in report.errors
        if not (
            environment == "callgenie"
            and finding.category == "security"
            and finding.rule == "SEC_PUBLIC_VM"
            and finding.resource == "vm.dg-cg-redis-vm"
        )
    ]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("environment", choices=["dev", "sit", "uat", "prod", "saafe", "callgenie"])
    args = parser.parse_args(argv)
    env_dir = Path("config/environments") / args.environment
    with Path("validation.json").open("w", encoding="utf-8") as output:
        with redirect_stdout(output):
            cmd_validate(argparse.Namespace(env_dir=str(env_dir), json=True))
    report = run_validation(env_dir)
    if unapproved_errors(args.environment, report):
        print(report.render())
        return 1
    return cmd_render(argparse.Namespace(
        env_dir=str(env_dir),
        out=f"environments/{args.environment}/.generated/deployment.normalized.json",
        force_security=bool(report.errors),
        reason=REASON if report.errors else None,
    ))


if __name__ == "__main__":
    raise SystemExit(main())
