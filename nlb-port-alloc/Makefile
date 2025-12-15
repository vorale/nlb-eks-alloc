# NLB Port Operator Makefile

# Configuration
IMAGE_NAME ?= nlb-port-operator
IMAGE_TAG ?= latest
REGISTRY ?= your-registry
IMAGE_FULL = $(REGISTRY)/$(IMAGE_NAME):$(IMAGE_TAG)

# Kubernetes
NAMESPACE ?= kube-system

.PHONY: help
help: ## Show this help message
	@echo 'Usage: make [target]'
	@echo ''
	@echo 'Available targets:'
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-20s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.PHONY: install-deps
install-deps: ## Install Python dependencies locally
	pip install -r requirements.txt

.PHONY: build
build: ## Build Docker image
	docker build -t $(IMAGE_FULL) .

.PHONY: push
push: ## Push Docker image to registry
	docker push $(IMAGE_FULL)

.PHONY: build-push
build-push: build push ## Build and push Docker image

.PHONY: setup-irsa
setup-irsa: ## Setup IAM roles for service account
	./setup-irsa.sh

.PHONY: deploy
deploy: ## Deploy operator to Kubernetes
	kubectl apply -f k8s/rbac.yaml
	kubectl apply -f k8s/configmap.yaml
	kubectl apply -f k8s/deployment.yaml

.PHONY: delete
delete: ## Delete operator from Kubernetes
	kubectl delete -f k8s/deployment.yaml --ignore-not-found
	kubectl delete -f k8s/configmap.yaml --ignore-not-found
	kubectl delete -f k8s/rbac.yaml --ignore-not-found

.PHONY: restart
restart: ## Restart operator deployment
	kubectl rollout restart deployment/nlb-port-operator -n $(NAMESPACE)

.PHONY: logs
logs: ## Show operator logs
	kubectl logs -n $(NAMESPACE) -l app=nlb-port-operator -f

.PHONY: status
status: ## Show operator status
	kubectl get pods -n $(NAMESPACE) -l app=nlb-port-operator
	kubectl get deploy -n $(NAMESPACE) nlb-port-operator

.PHONY: test-deploy
test-deploy: ## Deploy test service
	kubectl apply -f k8s/test-service.yaml

.PHONY: test-delete
test-delete: ## Delete test service
	kubectl delete -f k8s/test-service.yaml

.PHONY: test-check
test-check: ## Check test service status
	@echo "Service annotations:"
	@kubectl get svc game-room-1 -o jsonpath='{.metadata.annotations}' | jq
	@echo ""
	@echo "Allocated port:"
	@kubectl get svc game-room-1 -o jsonpath='{.metadata.annotations.nlb\.port-manager/allocated-port}'
	@echo ""
	@echo "Pods:"
	@kubectl get pods -l app=game-room-1 -o wide

.PHONY: clean
clean: ## Clean local build artifacts
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
	find . -type f -name "*.pyc" -delete 2>/dev/null || true

