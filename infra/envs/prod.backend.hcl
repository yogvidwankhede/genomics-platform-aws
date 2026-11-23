# terraform -chdir=infra/platform init -backend-config=../envs/prod.backend.hcl
# Replace ACCOUNT_ID with the value printed by the bootstrap stack (output state_bucket).
bucket = "gp-tfstate-ACCOUNT_ID-us-east-1"
key    = "platform/prod/terraform.tfstate"
region = "us-east-1"
