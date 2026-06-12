CLUSTER_NAME ?= vault-talk
NAMESPACE_PREFIX ?= dev
DEMO_HOST = hello.vault-talk.lan

.PHONY: generate-ca trust-ca add-hosts bootstrap-dev teardown-dev status flux-status flux-watch logs minikube-start minikube-stop load-images vault-env vault-shell

## CA management (run before the demo)
generate-ca:
	@mkdir -p manual/certs
	openssl genrsa -out manual/certs/ca-key.pem 4096
	openssl req -new -x509 -key manual/certs/ca-key.pem \
	    -out manual/certs/ca-cert.pem -days 3650 \
	    -subj "/CN=vault-talk-demo-ca/O=demo" \
	    -addext "basicConstraints=critical,CA:true"
	@echo ""
	@echo "CA generated at manual/certs/ca-cert.pem"
	@echo "Run: make trust-ca"

trust-ca:
	@if [ ! -f manual/certs/ca-cert.pem ]; then echo "ERROR: run 'make generate-ca' first"; exit 1; fi
	@if command -v update-ca-trust >/dev/null 2>&1; then \
	    sudo cp manual/certs/ca-cert.pem /etc/pki/ca-trust/source/anchors/vault-talk-demo-ca.pem && \
	    sudo update-ca-trust extract; \
	else \
	    sudo cp manual/certs/ca-cert.pem /usr/local/share/ca-certificates/vault-talk-demo-ca.crt && \
	    sudo update-ca-certificates; \
	fi
	@echo ""
	@echo "CA trusted system-wide."
	@echo "For Firefox/Chrome: import manual/certs/ca-cert.pem under Settings > Certificates > Authorities"
	@echo "  Path: $$(pwd)/manual/certs/ca-cert.pem"

## Cluster setup
minikube-start:
	minikube start -p $(CLUSTER_NAME) --driver=docker --cpus=4 --memory=8192
	minikube profile $(CLUSTER_NAME)

minikube-stop:
	minikube stop -p $(CLUSTER_NAME)
	minikube delete -p $(CLUSTER_NAME)

add-hosts:
	@MINIKUBE_IP=$$(minikube ip -p $(CLUSTER_NAME)) && \
	sudo sed -i '/$(DEMO_HOST)/d' /etc/hosts && \
	echo "$$MINIKUBE_IP $(DEMO_HOST)" | sudo tee -a /etc/hosts && \
	echo "Added: $$MINIKUBE_IP $(DEMO_HOST)" && \
	echo "  https://$(DEMO_HOST)"

## Image pre-loading (run after minikube-start, before bootstrap-dev)
## docker pull → host cache, then minikube image load → minikube containerd.
## Host Docker cache persists across minikube delete — run once per machine setup.
load-images:
	@echo "=== Pulling Flux images ==="
	@flux install --export 2>/dev/null | grep 'image:' | awk '{print $$2}' | sort -u | while read -r img; do \
	    echo "  docker pull $$img"; \
	    docker pull "$$img" || echo "WARN: could not pull $$img"; \
	    echo "  minikube image load $$img"; \
	    minikube image load "$$img" -p $(CLUSTER_NAME) || echo "WARN: could not load $$img"; \
	done
	@echo "=== Pulling Vault image ==="
	@vault_tag=$$(helm show values hashicorp/vault --version=0.30.1 2>/dev/null \
	    | grep -A2 'image:' | grep 'tag:' | head -1 | awk '{print $$2}' | tr -d '"'); \
	if [ -n "$$vault_tag" ]; then \
	    docker pull "hashicorp/vault:$$vault_tag" && \
	    minikube image load "hashicorp/vault:$$vault_tag" -p $(CLUSTER_NAME); \
	fi
	@echo "=== Pulling ESO image ==="
	docker pull ghcr.io/external-secrets/external-secrets:v0.19.2
	minikube image load ghcr.io/external-secrets/external-secrets:v0.19.2 -p $(CLUSTER_NAME)
	@echo "Done. Images loaded into minikube profile: $(CLUSTER_NAME)"

## Vault access
vault-env:
	@minikube service dev-vault -n dev-vault -p $(CLUSTER_NAME) --url 2>/dev/null | head -1 | xargs -I{} echo 'export VAULT_ADDR={} VAULT_TOKEN=root'

vault-shell:
	@VAULT_ADDR=$$(minikube service dev-vault -n dev-vault -p $(CLUSTER_NAME) --url 2>/dev/null | head -1) \
	VAULT_TOKEN=root \
	bash --rcfile <(echo "export VAULT_ADDR=$$VAULT_ADDR VAULT_TOKEN=root && PS1='[vault] \w \$$ '")

## Bootstrap and teardown
bootstrap-dev:
	./manual/scripts/bootstrap.sh

teardown-dev:
	@echo "Deleting app and infrastructure namespaces..."
	kubectl delete namespace --ignore-not-found \
	    $(NAMESPACE_PREFIX)-hello \
	    $(NAMESPACE_PREFIX)-cert-manager \
	    $(NAMESPACE_PREFIX)-traefik \
	    $(NAMESPACE_PREFIX)-vault \
	    external-secrets-system \
	    flux-system
	@echo "Removing Flux CRDs..."
	kubectl delete crd --ignore-not-found -l app.kubernetes.io/part-of=flux
	@echo "Removing cert-manager ClusterIssuer and ClusterRoleBindings..."
	kubectl delete clusterissuer --all --ignore-not-found
	kubectl delete clusterrolebinding cert-manager-auth-delegator cert-manager-vault-token --ignore-not-found
	kubectl delete clusterrole cert-manager-vault-token --ignore-not-found
	@echo "Done."

## Flux observability
status:
	@echo "=== Kustomizations ==="
	flux get kustomizations
	@echo ""
	@echo "=== HelmReleases ==="
	flux get helmreleases -A

flux-status:
	flux get kustomizations -A
	flux get helmreleases -A || true

flux-watch:
	flux get kustomizations --watch --timeout=10m

logs:
	flux logs --follow --tail=100
