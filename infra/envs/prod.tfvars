environment        = "prod"
region             = "us-east-1"
owner              = "yogvid"
cost_center        = "portfolio"
az_count           = 2
max_vcpus          = 64
monthly_budget_usd = 50
force_destroy      = false
# One trail per account: dev already creates it when both live in the same account.
enable_cloudtrail = false
