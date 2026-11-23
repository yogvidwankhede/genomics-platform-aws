# Branch protection and repository settings

These settings live in GitHub, not in code. Apply them once after the repository is created
(Settings → Branches / Environments), or with the `gh api` calls below.

## `main` ruleset

| Setting | Value | Why |
|---|---|---|
| Require a pull request before merging | on, 1 approval, dismiss stale approvals | no direct pushes; every change is reviewed |
| Require review from Code Owners | on | `.github/CODEOWNERS` owns infra and workflows |
| Required status checks | `python (ruff + pytest)`, `nextflow (lint + stub + nf-test)`, `terraform (fmt + validate + tflint + test)`, `checkov (IaC security)`, `container (build + Trivy)` | merge only when the full CI gate is green |
| Require branches to be up to date | on | checks ran against what will land |
| Require conversation resolution | on | |
| Require linear history | off | stacked milestone PRs are merged with merge commits |
| Block force pushes / deletions | on | |
| Restrict who can push | admins only, and only through PRs | |

## Environments

| Environment | Protection | Variables |
|---|---|---|
| `dev` | deployment branch: `main` only | `AWS_APPLY_ROLE_ARN` = bootstrap output `github_apply_role_arns.dev` |
| `prod` | deployment branch: `main` only, **required reviewers: @yogvidwankhede**, wait timer 5 min | `AWS_APPLY_ROLE_ARN` = `github_apply_role_arns.prod` |

The prod apply role trusts only OIDC tokens whose subject is
`repo:yogvidwankhede/genomics-platform-aws:environment:prod`. A workflow can only get that
token after the Environment's reviewers approve, so the approval gate is enforced by AWS
IAM as well as by GitHub.

## Repository variables (no secrets)

| Variable | Value |
|---|---|
| `AWS_PLAN_ROLE_ARN` | bootstrap output `github_plan_role_arn` |
| `TF_STATE_BUCKET` | bootstrap output `state_bucket` |
| `AWS_REGION` | `us-east-1` |
| `AWS_DEPLOY_ENABLED` | `true` once bootstrap has been applied; until then deploy jobs skip |

No AWS access keys are stored anywhere. CI authenticates only through GitHub OIDC.

## CLI equivalent

```bash
gh api -X PUT repos/yogvidwankhede/genomics-platform-aws/environments/prod \
  -f 'reviewers[][type]=User' -F "reviewers[][id]=$(gh api users/yogvidwankhede -q .id)" \
  -F wait_timer=5 -F 'deployment_branch_policy[protected_branches]=true' \
  -F 'deployment_branch_policy[custom_branch_policies]=false'
gh variable set AWS_PLAN_ROLE_ARN --body "<github_plan_role_arn>"
gh variable set TF_STATE_BUCKET   --body "<state_bucket>"
```
