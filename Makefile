# genomics-platform-aws: one entry point for local checks, infra and teardown.
# `make help` lists targets. Infra targets take ENV=dev|prod (default dev).

SHELL        := /bin/bash
.SHELLFLAGS  := -euo pipefail -c
ENV          ?= dev
TF_PLATFORM  := terraform -chdir=infra/platform
TF_BOOTSTRAP := terraform -chdir=infra/bootstrap
TFVARS       := -var-file=../envs/$(ENV).tfvars
PLAN_FILE    := $(ENV).tfplan
TFLINT_IMAGE := ghcr.io/terraform-linters/tflint:v0.60.0
PYTHON       ?= $(if $(wildcard .venv/bin/python),.venv/bin/python,python3)
HOURS        ?= 3
RUNS         ?= 1

.DEFAULT_GOAL := help
.PHONY: help
help: ## List targets
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-22s\033[0m %s\n",$$1,$$2}'

# ---- pipeline ------------------------------------------------------------------------------
.PHONY: test-pipeline stub-pipeline benchmark-data benchmark
test-pipeline: ## nf-test: module + pipeline tests (Docker)
	cd pipeline && nf-test test

stub-pipeline: ## Wire-check the whole DAG with -stub
	cd pipeline && nextflow run . -profile test,docker -stub --outdir ../results/stub

benchmark-data: ## Fetch GIAB HG001 chr20:10-12Mb reads, reference and truth
	scripts/fetch_benchmark_data.sh data/benchmark

benchmark: benchmark-data ## Run the GIAB benchmark locally (CALLER=gatk|deepvariant)
	cd pipeline && nextflow run . -profile benchmark,docker --caller $${CALLER:-gatk} \
	  --outdir ../data/runs/benchmark-local-$${CALLER:-gatk} -resume

# ---- M7 research benchmark (local, $0 AWS) --------------------------------------------------
.PHONY: research-data research-matrix research-repro research-analyze test-research research
RESEARCH_CFG := ../../../research/conf/research.config

research-data: ## Fetch HG001 + HG002/HG003/HG004 reads, GIAB truth and v3.6 stratifications
	research/scripts/fetch_research_data.sh data/research
	$(PYTHON) research/scripts/make_matrix.py --out data/research/samplesheet_matrix.csv

research-matrix: ## Run the 28-row x 2-caller experiment matrix (one Nextflow run, resumable)
	mkdir -p data/launch/matrix && cd data/launch/matrix && \
	  nextflow -c $(RESEARCH_CFG) run ../../../pipeline -profile docker -resume

research-repro: ## Reproducibility runs: repeat, thread-count and -K on/off (GATK, HG001 benchmark)
	research/scripts/run_repro.sh

research-analyze: ## Tables + figures for docs/report.md from run outputs
	cd research/analysis && PYTHONPATH=src ../../$(PYTHON) -m gp_research.analyze matrix \
	  --results ../../data/runs/research-matrix --data ../../data/research \
	  --out ../results --figures ../../docs/figures

test-research: ## pytest for the statistics package
	cd research/analysis && ../../$(PYTHON) -m pytest

research: research-data research-matrix research-repro research-analyze ## Everything above, in order

# ---- terraform quality gates (no AWS credentials needed) -----------------------------------
.PHONY: tf-fmt tf-validate tf-lint tf-sec tf-test tf-check
tf-fmt: ## terraform fmt -check
	terraform fmt -check -recursive infra

tf-validate: ## terraform validate every root and module
	for d in infra/bootstrap infra/platform infra/modules/*; do \
	  terraform -chdir=$$d init -backend=false -input=false >/dev/null && terraform -chdir=$$d validate -no-color; done

tf-lint: ## tflint (AWS ruleset) via the pinned container
	docker run --rm -v "$$PWD:/data" -w /data/infra -e TFLINT_PLUGIN_DIR=/data/.tflint.d $(TFLINT_IMAGE) --init --config /data/.tflint.hcl
	docker run --rm -v "$$PWD:/data" -w /data/infra -e TFLINT_PLUGIN_DIR=/data/.tflint.d $(TFLINT_IMAGE) --recursive --config /data/.tflint.hcl

tf-sec: ## checkov 3.4.6 on Python 3.13 in an isolated env (same as CI)
	uvx --python 3.13 checkov==3.4.6 -d infra --framework terraform --quiet --compact

tf-test: ## terraform test (mocked AWS provider, offline plans)
	for d in infra/platform infra/modules/batch infra/modules/storage; do \
	  terraform -chdir=$$d init -backend=false -input=false >/dev/null && terraform -chdir=$$d test -no-color; done

tf-check: tf-fmt tf-validate tf-lint tf-sec tf-test ## All offline Terraform gates

# ---- AWS (needs credentials; never run in CI without the approval gate) -------------------
.PHONY: bootstrap-plan bootstrap-apply init plan cost apply destroy
bootstrap-plan: ## Plan the state bucket + GitHub OIDC roles (local state)
	$(TF_BOOTSTRAP) init -input=false
	$(TF_BOOTSTRAP) plan -out=bootstrap.tfplan

bootstrap-apply: ## Apply the reviewed bootstrap plan
	$(TF_BOOTSTRAP) apply bootstrap.tfplan

init: ## terraform init against envs/$(ENV).backend.hcl (TF_STATE_BUCKET= overrides the bucket)
	$(TF_PLATFORM) init -input=false -reconfigure -backend-config=../envs/$(ENV).backend.hcl $(if $(TF_STATE_BUCKET),-backend-config=bucket=$(TF_STATE_BUCKET))

cost: ## Print the pre-apply cost estimate (HOURS=, RUNS=)
	python3 scripts/cost_estimate.py $(ENV) --hours-up $(HOURS) --runs $(RUNS)

plan: build-api init ## Plan $(ENV) to a plan file and show the cost estimate
	$(TF_PLATFORM) plan $(TFVARS) -out=$(PLAN_FILE)
	@$(MAKE) --no-print-directory cost ENV=$(ENV)

apply: ## Apply the saved plan; requires CONFIRM=yes after reading `make plan`
	@$(MAKE) --no-print-directory cost ENV=$(ENV)
	@if [[ "$${CONFIRM:-}" != "yes" ]]; then echo "Refusing to apply: re-run with CONFIRM=yes after reviewing the plan and estimate."; exit 1; fi
	$(TF_PLATFORM) apply $(PLAN_FILE)

destroy: ## Tear down $(ENV) completely (one command)
	@echo "Destroying $(ENV). Buckets/repos are force-deleted only where force_destroy=true (dev)."
	$(MAKE) --no-print-directory init ENV=$(ENV) >/dev/null
	$(TF_PLATFORM) destroy $(TFVARS) -auto-approve
	@echo "Done. Verify nothing billable remains: make verify-teardown ENV=$(ENV)"

.PHONY: verify-teardown
verify-teardown: ## List any remaining gp-$(ENV) endpoints, instances, buckets
	aws ec2 describe-vpc-endpoints --filters Name=tag:Environment,Values=$(ENV) Name=tag:Project,Values=genomics-platform --query 'VpcEndpoints[].VpcEndpointId'
	aws ec2 describe-instances --filters Name=tag:Name,Values=gp-$(ENV)-batch Name=instance-state-name,Values=pending,running --query 'Reservations[].Instances[].InstanceId'
	aws s3api list-buckets --query "Buckets[?starts_with(Name, 'gp-$(ENV)-')].Name"

# ---- M3: run the benchmark on AWS Batch (after `make apply ENV=...`) ------------------------
.PHONY: stage-awscli mirror-images push-head submit-benchmark test-trigger head-image
VERSION = $(shell sed -nE "s/^[[:space:]]+version[[:space:]]+= '(.*)'/\1/p" pipeline/nextflow.config | head -1)
TF_OUT  = terraform -chdir=infra/platform output

head-image: ## Build the Nextflow head image locally (no push)
	docker build --platform linux/amd64 -f containers/nextflow-head/Dockerfile --build-arg PIPELINE_VERSION=$(VERSION) -t gp/nextflow-head:$(VERSION) .

stage-awscli: ## Upload the AWS CLI bundle Batch instances install at boot
	scripts/stage_awscli.sh "$$($(TF_OUT) -json buckets | python3 -c 'import json,sys;print(json.load(sys.stdin)["artifacts"])')"

mirror-images: ## Copy every pinned tool image into the ECR mirror
	scripts/mirror_images.sh "$$($(TF_OUT) -raw ecr_registry)"

push-head: ## Build + push the head image tagged with the pipeline version
	scripts/push_head_image.sh "$$($(TF_OUT) -raw head_repository_url)" $(VERSION)

submit-benchmark: ## Upload GIAB slice and start a run (MODE=direct|event, CALLER=gatk|deepvariant)
	scripts/submit_benchmark.sh $(ENV)

test-trigger: ## pytest for the trigger Lambdas
	cd services/trigger && ../../.venv/bin/pytest --cov=gp_trigger

test-api: ## pytest for the REST API
	cd services/api && ../../.venv/bin/pytest --cov=gp_api

venv: ## Create .venv (Python 3.13 = Lambda runtime) with pinned dev deps
	python3.13 -m venv .venv
	.venv/bin/pip install -q -r requirements-dev.txt

lint-python: ## ruff lint + format check
	.venv/bin/ruff check services pipeline/bin scripts
	.venv/bin/ruff format --check services pipeline/bin scripts

.PHONY: build-api
build-api: ## Build the API Lambda zip (no-op until services/api exists)
	PYTHON=$(PYTHON) scripts/build_api.sh

.PHONY: preflight
preflight: ## Read-only account checks before apply (limits that broke the first deploy)
	scripts/preflight.sh $(ENV)
