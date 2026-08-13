# eks-sre-demo
#
# Targets are grouped by what they cost:
#   FREE     - no cluster required, no AWS spend
#   BILLED   - requires a running EKS cluster (~$0.34/hr, see docs/plan.md s10)
#
# Values come from `terraform output`. Nothing account-specific is committed.

SHELL := /bin/bash
.DEFAULT_GOAL := help

APP_DIR    ?= app
IMAGE_NAME ?= sre-demo-api
IMAGE_TAG  ?= $(shell git rev-parse HEAD 2>/dev/null || echo dev)
NAMESPACE  ?= demo
RELEASE    ?= demo-api
TF_DIR     ?= infra/environments/demo
VENV       ?= .venv

# Populate from: make tf-output
AWS_REGION     ?=
ECR_REPOSITORY ?=
DEMO_BUCKET    ?=

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------- FREE --------

.PHONY: venv
venv: ## FREE  Create the local virtualenv
	python3 -m venv $(VENV)
	$(VENV)/bin/python -m pip install --upgrade pip pip-tools
	$(VENV)/bin/python -m pip install -r $(APP_DIR)/requirements.lock
	$(VENV)/bin/python -m pip install pytest httpx ruff

.PHONY: test
test: ## FREE  Run unit tests
	cd $(APP_DIR) && ../$(VENV)/bin/python -m pytest

.PHONY: lint
lint: ## FREE  Lint and format-check
	cd $(APP_DIR) && ../$(VENV)/bin/ruff check .
	cd $(APP_DIR) && ../$(VENV)/bin/ruff format --check .

.PHONY: lock
lock: ## FREE  Regenerate the hash-pinned lock file (inside python:3.14)
	docker run --rm -v "$(PWD)/$(APP_DIR)":/w -w /w python:3.14-slim sh -c \
	  'pip install -q pip-tools && pip-compile --quiet --generate-hashes \
	   --strip-extras --output-file requirements.lock requirements.in'

.PHONY: build
build: ## FREE  Build the container image
	docker build --build-arg GIT_SHA=$(IMAGE_TAG) -t $(IMAGE_NAME):$(IMAGE_TAG) $(APP_DIR)

.PHONY: smoke
smoke: build ## FREE  Run the image locally and hit every endpoint
	@docker rm -f api-smoke >/dev/null 2>&1 || true
	docker run -d --name api-smoke --read-only --tmpfs /tmp:rw,size=64m \
	  -p 8080:8080 $(IMAGE_NAME):$(IMAGE_TAG) >/dev/null
	@sleep 3
	@for p in /health/live /health/ready / /api/v1/work /api/v1/config; do \
	  printf '  %-16s ' $$p; curl -fsS --retry 5 --retry-delay 1 http://localhost:8080$$p; echo; \
	done
	@docker rm -f api-smoke >/dev/null

.PHONY: render
render: ## FREE  Render both delivery stages (no cluster needed)
	@echo "--- stage 1: kustomize ---"
	kubectl kustomize k8s/overlays/eks > /tmp/stage1.yaml && echo "  ok"
	@echo "--- stage 2: helm ---"
	helm lint charts/api
	helm template $(RELEASE) charts/api -f gitops/environments/demo/values.yaml > /tmp/stage2.yaml && echo "  ok"

.PHONY: validate
validate: render ## FREE  Schema-validate both stages with kubeconform
	@command -v kubeconform >/dev/null || { echo "install kubeconform first"; exit 1; }
	kubeconform -strict -summary -ignore-missing-schemas /tmp/stage1.yaml /tmp/stage2.yaml

.PHONY: tf-fmt tf-validate
tf-fmt: ## FREE  terraform fmt
	cd $(TF_DIR) && terraform fmt -recursive

tf-validate: ## FREE  terraform validate (no credentials needed)
	cd $(TF_DIR) && terraform init -backend=false -input=false >/dev/null && terraform validate

.PHONY: check
check: lint test render tf-validate ## FREE  Everything that runs without a cluster
	@echo "all free checks passed"

# -------------------------------------------------------------- BILLED --------

.PHONY: tf-plan
tf-plan: ## BILLED(0) Plan infrastructure - needs credentials, creates nothing
	cd $(TF_DIR) && terraform plan -out tfplan

.PHONY: tf-apply
tf-apply: ## BILLED   Create the cluster. THE METER STARTS HERE.
	@echo "This creates ~\$$0.34/hr of AWS resources. Budget set? (docs/plan.md s10.5)"
	@read -p "Type yes to continue: " ok && [ "$$ok" = "yes" ]
	cd $(TF_DIR) && terraform apply tfplan

.PHONY: tf-output
tf-output: ## Show the values the other targets need
	@cd $(TF_DIR) && terraform output

.PHONY: kubeconfig
kubeconfig: ## Point kubectl at the cluster
	aws eks update-kubeconfig --region $(AWS_REGION) --name sre-demo

.PHONY: ecr-login push
ecr-login:
	aws ecr get-login-password --region $(AWS_REGION) \
	  | docker login --username AWS --password-stdin $(firstword $(subst /, ,$(ECR_REPOSITORY)))

push: build ecr-login ## BILLED   Push the immutable SHA image to ECR
	docker tag $(IMAGE_NAME):$(IMAGE_TAG) $(ECR_REPOSITORY):$(IMAGE_TAG)
	docker push $(ECR_REPOSITORY):$(IMAGE_TAG)

.PHONY: apply-stage1
apply-stage1: ## BILLED   Ladder stage 1: kubectl apply -k
	@test -n "$(ECR_REPOSITORY)" || { echo "set ECR_REPOSITORY (make tf-output)"; exit 1; }
	@# Substitute placeholders into a temp copy so no account ID is ever written
	@# back into a tracked file.
	rm -rf /tmp/stage1-overlay && cp -r k8s /tmp/stage1-overlay
	sed -i -e 's|PLACEHOLDER_ECR_REPOSITORY|$(ECR_REPOSITORY)|g' \
	       -e 's|PLACEHOLDER_IMAGE_TAG|$(IMAGE_TAG)|g' \
	       -e 's|PLACEHOLDER_AWS_REGION|$(AWS_REGION)|g' \
	       -e 's|PLACEHOLDER_DEMO_BUCKET|$(DEMO_BUCKET)|g' \
	       /tmp/stage1-overlay/overlays/eks/kustomization.yaml \
	       /tmp/stage1-overlay/overlays/eks/patch-env.yaml
	kubectl apply -k /tmp/stage1-overlay/overlays/eks
	kubectl -n $(NAMESPACE) rollout status deploy/demo-api --timeout=5m

.PHONY: apply-stage2
apply-stage2: ## BILLED   Ladder stage 2: helm upgrade --install
	helm upgrade --install $(RELEASE) charts/api \
	  --namespace $(NAMESPACE) --create-namespace \
	  --set image.repository=$(ECR_REPOSITORY) \
	  --set image.tag=$(IMAGE_TAG) \
	  --set env.AWS_REGION=$(AWS_REGION) \
	  --set env.DEMO_BUCKET=$(DEMO_BUCKET) \
	  --atomic --timeout 10m

.PHONY: diff-stages
diff-stages: ## BILLED   Prove stage 1 and stage 2 agree on the live cluster
	helm template $(RELEASE) charts/api -f gitops/environments/demo/values.yaml | kubectl diff -f - || true

.PHONY: evidence
evidence: ## BILLED   Capture sanitized evidence (survives teardown)
	@mkdir -p docs/evidence
	@echo "Capturing to docs/evidence/ - REDACT account IDs and hostnames before committing"
	kubectl -n $(NAMESPACE) get deploy,rs,pod,svc,endpointslice,ingress -o wide \
	  > docs/evidence/cluster-state.txt
	kubectl -n $(NAMESPACE) get deploy demo-api --show-managed-fields -o yaml \
	  > docs/evidence/managed-fields.yaml
	@echo "  done. Review both files for identifiers before git add."

.PHONY: destroy
destroy: ## BILLED   Ordered teardown. Ingress first, cluster last.
	@echo "Deleting Ingress and waiting for the ALB to disappear..."
	-kubectl -n $(NAMESPACE) delete ingress --all --ignore-not-found
	@echo "Confirm the ALB is gone before continuing:"
	aws elbv2 describe-load-balancers --region $(AWS_REGION) \
	  --query 'LoadBalancers[].LoadBalancerName' --output text
	@read -p "ALB gone? Type yes to terraform destroy: " ok && [ "$$ok" = "yes" ]
	cd $(TF_DIR) && terraform destroy

.PHONY: orphans
orphans: ## Check for billable resources left behind after destroy
	@echo "--- load balancers ---"; aws elbv2 describe-load-balancers --region $(AWS_REGION) --query 'LoadBalancers[].LoadBalancerName' --output text
	@echo "--- nat gateways ---";   aws ec2 describe-nat-gateways --region $(AWS_REGION) --filter Name=state,Values=available,pending --query 'NatGateways[].NatGatewayId' --output text
	@echo "--- elastic ips ---";    aws ec2 describe-addresses --region $(AWS_REGION) --query 'Addresses[].AllocationId' --output text
	@echo "--- volumes ---";        aws ec2 describe-volumes --region $(AWS_REGION) --filters Name=status,Values=available --query 'Volumes[].VolumeId' --output text
	@echo "--- clusters ---";       aws eks list-clusters --region $(AWS_REGION) --query 'clusters' --output text
