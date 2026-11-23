# Contributing

Thanks for helping. This project is run like a small platform team: every change lands through
a pull request with green CI.

## Development setup

```bash
make venv
make test-pipeline
make tf-check
make test-trigger test-api test-research lint-python
pre-commit install
```

- `make venv` creates the Python 3.13 virtualenv with pinned dev dependencies.
- `make test-pipeline` runs nf-test (needs Docker; on Apple Silicon enable Rosetta for amd64 images).
- `make tf-check` runs fmt, validate, tflint, checkov and terraform test, with no AWS credentials needed.
- `make test-trigger test-api test-research lint-python` runs the Python tests and ruff.
- `pre-commit install` adds gitleaks, ruff and terraform fmt/validate on every commit.

## Conventions

- **Commits:** [Conventional Commits](https://www.conventionalcommits.org/) (`feat(pipeline): …`,
  `fix(infra): …`). release-please uses them to version releases and write `CHANGELOG.md`.
- **Pipeline:** DSL2 modules with a pinned container (immutable tag) and a `stub:` block.
  Add or extend nf-test coverage for behaviour changes.
- **Terraform:** reusable modules under `infra/modules`, one root in `infra/platform`, and
  environment differences only in `infra/envs/*.tfvars`. New guard-rails get a `terraform test`.
- **Claims:** numbers in docs must come from a run recorded in `RESULTS.md`. Say plainly what
  was not measured.

## Pull requests

Fill in the PR template (what, how verified, rollback). CI must pass: python, nextflow
(lint + stub + nf-test), terraform, checkov and container (Trivy). Infrastructure changes get a
`terraform plan` comment when the OIDC plan role is configured.
