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

.PHONY: init plan apply credentials bridge bootstrap argocd-ui destroy

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
