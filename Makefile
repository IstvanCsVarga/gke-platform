PROJECT ?= $(shell gcloud config get-value project 2>/dev/null)
ZONE    ?= europe-west4-a
GPU     ?= false
CLUSTER := platform
TF      := terraform -chdir=terraform
TFVARS  := -var project_id=$(PROJECT) -var zone=$(ZONE) -var gpu_pool=$(GPU)

# Every kubectl/helm call names this cluster explicitly, never the current context.
CONTEXT := gke_$(PROJECT)_$(ZONE)_$(CLUSTER)
KUBECTL := kubectl --context $(CONTEXT)

ARGOCD_CHART_VERSION := 10.10.5

# Local stand-in on kind: the same Argo CD values, root app and Git source, no GCP.
LOCAL_CLUSTER := platform-local
LOCAL_KUBECTL := kubectl --context kind-$(LOCAL_CLUSTER)

# The repo Argo CD reads from, as the root app has it now. `make use-repo` changes it.
REPO_NOW = $(shell sed -n 's/^ *repoURL: //p' gitops/bootstrap/root.yaml)
REPO_FILES := gitops/bootstrap/root.yaml gitops/platform/projects.yaml gitops/platform/teams.yaml

.PHONY: init plan apply credentials bridge bootstrap argocd-ui destroy local-up local-ui local-down use-repo

init:
	$(TF) init -backend-config=bucket=$(PROJECT)-tfstate

plan:
	$(TF) plan $(TFVARS)

apply:
	$(TF) apply $(TFVARS)
	@if $(KUBECTL) get namespace argocd >/dev/null 2>&1; then $(MAKE) bridge; fi

# DNS endpoint: authorised by IAM (container.clusters.connect), no IP allowlist.
credentials:
	gcloud container clusters get-credentials $(CLUSTER) --location $(ZONE) --project $(PROJECT) --dns-endpoint

# Terraform -> Argo CD: publish Terraform outputs (bucket names) on the cluster secret.
bridge:
	$(TF) output -raw argocd_cluster_secret | $(KUBECTL) apply -f -

# Argo CD is the one thing installed imperatively; from here on Git is the source of truth.
bootstrap: credentials
	helm upgrade --install argocd argo-cd --repo https://argoproj.github.io/argo-helm \
		--kube-context $(CONTEXT) --version $(ARGOCD_CHART_VERSION) \
		--namespace argocd --create-namespace --values gitops/bootstrap/argocd-values.yaml --wait
	$(MAKE) bridge
	$(KUBECTL) apply -f gitops/bootstrap/root.yaml

argocd-ui:
	@$(KUBECTL) -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
	$(KUBECTL) -n argocd port-forward svc/argocd-server 8080:443

# Team namespaces go first, so the CSI driver deletes their persistent disks;
# destroying the cluster first would orphan them, and they would keep billing.
# Argo CD is told never to delete databases, so this deletes them explicitly,
# and stops before terraform destroy if any volume is left.
destroy:
	@if gcloud container clusters describe $(CLUSTER) --location $(ZONE) --project $(PROJECT) >/dev/null 2>&1; then \
		$(MAKE) credentials && \
		$(KUBECTL) -n argocd delete application root --ignore-not-found && \
		$(KUBECTL) -n argocd delete applicationset teams --ignore-not-found --wait && \
		$(KUBECTL) delete namespace -l team --wait --timeout=15m && \
		if $(KUBECTL) get pv -o name | grep -q .; then $(KUBECTL) wait --for=delete pv --all --timeout=10m; fi; \
	fi
	$(TF) destroy $(TFVARS)

# kind instead of Terraform; local/cluster-secret.yaml instead of `make bridge`.
local-up:
	kind get clusters | grep -qx $(LOCAL_CLUSTER) || kind create cluster --name $(LOCAL_CLUSTER) --config local/kind.yaml
	helm upgrade --install argocd argo-cd --repo https://argoproj.github.io/argo-helm \
		--kube-context kind-$(LOCAL_CLUSTER) --version $(ARGOCD_CHART_VERSION) \
		--namespace argocd --create-namespace --values gitops/bootstrap/argocd-values.yaml --wait
	$(LOCAL_KUBECTL) apply -f local/cluster-secret.yaml
	$(LOCAL_KUBECTL) apply -f gitops/bootstrap/root.yaml

local-ui:
	@$(LOCAL_KUBECTL) -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
	$(LOCAL_KUBECTL) -n argocd port-forward svc/argocd-server 8080:443

local-down:
	kind delete cluster --name $(LOCAL_CLUSTER)

# Points Argo CD at a fork: the root app, the teams AppProject and the teams
# ApplicationSet all name the repo. Commit and push the result to the fork.
use-repo:
	@test -n "$(REPO)" || { echo "usage: make use-repo REPO=https://github.com/<you>/gke-platform"; exit 1; }
	OLD='$(REPO_NOW)' NEW='$(REPO)' perl -pi -e 's/\Q$$ENV{OLD}\E/$$ENV{NEW}/g' $(REPO_FILES)
	@grep -c '$(REPO)' $(REPO_FILES)
