# Security policy

## Reporting a vulnerability

Please **do not open a public issue** for security problems. Use GitHub's
[private vulnerability reporting](https://github.com/yogvidwankhede/genomics-platform-aws/security/advisories/new)
instead. You should get an acknowledgement within 5 working days.

## Scope

This repository is a reference platform that processes **public GIAB data only**. It is not
intended for PHI without a separate compliance review. In-scope issues include:

- IAM policies broader than documented (least privilege is a design goal)
- ways to read or write another run's data, or to override platform-owned pipeline parameters
  through `params.json`
- secrets or credentials committed to the repository, or a CI workflow that could leak the
  OIDC role to forks
- vulnerable pinned container images (`.trivyignore` lists accepted findings, each with a
  reason and a review date)

## How the platform is protected

The security model (OIDC-only CI, NAT-less VPC, KMS everywhere, IMDSv2 hop limit 1, IAM-only
API, input validation) is described in the [README](README.md#security-model). Continuous
checks: checkov (IaC), Trivy (images), gitleaks (pre-commit), Dependabot.
