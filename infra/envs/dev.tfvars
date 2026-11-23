environment = "dev"
region      = "us-east-1"
owner       = "yogvid"
cost_center = "portfolio"
az_count    = 1
# AWS Free plan account: EC2 only launches Free Tier eligible types, and the Spot quota is
# 5 vCPUs. Two 2-vCPU flex instances (head job on one, a task on the other) fit both limits.
max_vcpus            = 4
batch_instance_types = ["m7i-flex.large", "c7i-flex.large"]
pipeline_version     = "0.1.4"
pipeline_params = {
  max_cpus   = "2"
  max_memory = "6.GB" # m7i-flex.large has 8 GiB; leave room for the ECS agent
}
monthly_budget_usd = 10
force_destroy      = true
enable_cloudtrail  = true
# New accounts: 10 concurrent Lambda executions in total and no reservations allowed.
reserve_lambda_concurrency = false
