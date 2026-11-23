# ADR-0003: Terraform state and environment layout

**Status:** Accepted, 2026-11-22

## Context
Two environments (dev, prod) must stay structurally identical without copy-paste, must never
share state, and CI must be able to plan both on every PR.

## Decision
- **One root module** (`infra/platform`) composes seven reusable modules. Environments differ
  only in `infra/envs/<env>.tfvars` (sizing, AZs, force_destroy, budget) and
  `infra/envs/<env>.backend.hcl` (state key `platform/<env>/terraform.tfstate`).
- **Remote state** in one S3 bucket from the `bootstrap` stack: versioned, SSE-KMS (dedicated
  CMK), TLS-only, public access blocked. **Locking uses S3-native lockfiles**
  (`use_lockfile = true`, Terraform ≥ 1.10), so no DynamoDB lock table is needed.
- The bootstrap stack keeps local state (chicken-and-egg). It is tiny and rarely changes, and can
  be migrated into the bucket afterwards.
- Providers are pinned (`~> 6.73`), `required_version` is bounded, and `.terraform.lock.hcl` is
  committed for linux/darwin × amd64/arm64.

## Alternatives
- **Workspaces:** the same backend config makes it easy to apply to the wrong env, and the
  backend key isn't explicit in review. Rejected.
- **Directory per env (`envs/dev/main.tf`) calling modules:** duplicates the module wiring.
  Rejected (copy-paste).
- **Terragrunt:** good at scale, but an extra tool for two environments. Revisit at more than
  three envs or accounts.

## Consequences
- Promoting dev → prod is the same code with different tfvars, gated by the prod GitHub
  Environment (see docs/branch-protection.md).
- For stronger isolation, prod should move to its own AWS account; only the backend file,
  tfvars and the OIDC trust need to change.
