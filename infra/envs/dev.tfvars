environment = "dev"
region      = "us-east-1"
owner       = "yogvid"
cost_center = "portfolio"
az_count    = 1
# New accounts get a 5-vCPU Spot quota; 4 keeps every placement inside it (head 1 + task 3).
max_vcpus          = 4
monthly_budget_usd = 10
force_destroy      = true
enable_cloudtrail  = true
# New accounts: 10 concurrent Lambda executions in total and no reservations allowed.
reserve_lambda_concurrency = false
