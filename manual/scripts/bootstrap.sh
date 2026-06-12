#!/usr/bin/env bash
# bootstrap.sh — Vault Talk Demo Bootstrap
#
# Sets up a local minikube cluster with:
#   Vault (dev mode) → ESO → FluxCD
# Then Flux installs cert-manager, Traefik, and the hello-world app.
#
# Run: make bootstrap-dev
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────
ENVIRONMENT="dev"
NAMESPACE_PREFIX="${NAMESPACE_PREFIX:-dev}"
CLUSTER_NAME="${CLUSTER_NAME:-vault-talk}"

VAULT_TOKEN="${VAULT_TOKEN:-root}"

GITHUB_USER="${GITHUB_USER:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
GITHUB_REPO="${GITHUB_REPO:-self-2026-vault-talk}"
GITHUB_BRANCH="${GITHUB_BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)}"
GITHUB_OWNER="${GITHUB_OWNER:-josephtate}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ─────────────────────────────────────────────────────────────────────────────
# Logging helpers
# ─────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
section() { echo -e "\n${YELLOW}══ $1 ══${NC}"; }

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────
kctl() { kubectl "$@" --context="$CLUSTER_NAME"; }

get_vault_url() {
    minikube -p "$CLUSTER_NAME" service "${ENVIRONMENT}-vault" -n "${ENVIRONMENT}-vault" --url 2>/dev/null | head -n1
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 0: Prerequisites
# ─────────────────────────────────────────────────────────────────────────────
check_prerequisites() {
    section "Prerequisites"

    # CA certificates must be generated before bootstrap
    if [[ ! -f "$REPO_ROOT/manual/certs/ca-cert.pem" || ! -f "$REPO_ROOT/manual/certs/ca-key.pem" ]]; then
        error "CA certificates not found at manual/certs/"
        error "Run: make generate-ca"
        exit 1
    fi

    local missing=()
    for tool in kubectl helm vault flux minikube envsubst docker; do
        command -v "$tool" &>/dev/null || missing+=("$tool")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing tools: ${missing[*]}"
        exit 1
    fi

    if ! kctl cluster-info &>/dev/null; then
        error "Cannot connect to cluster. Run: make minikube-start"
        exit 1
    fi

    if [[ -z "$GITHUB_TOKEN" ]]; then
        error "GITHUB_TOKEN is required for Flux to pull from GitHub"
        error "Set it in .envrc.${USER} or export GITHUB_TOKEN=..."
        exit 1
    fi

    success "Prerequisites OK"
}

# ─────────────────────────────────────────────────────────────────────────────
# Image pre-loading
# Pulls to the host Docker daemon first, then loads into minikube's containerd.
# Host Docker cache persists across minikube delete/start — pull once, load fast.
# ─────────────────────────────────────────────────────────────────────────────
preload_images() {
    section "Pre-loading images into minikube"
    info "docker pull → host cache, then minikube image load → minikube containerd"

    helm repo add hashicorp https://helm.releases.hashicorp.com --force-update &>/dev/null || true
    helm repo add external-secrets https://charts.external-secrets.io --force-update &>/dev/null || true

    local all_images=()

    # Flux images — extract from flux install manifest
    local flux_images
    flux_images=$(flux install --export 2>/dev/null | grep 'image:' | awk '{print $2}' | sort -u) || true
    if [[ -n "$flux_images" ]]; then
        while IFS= read -r img; do
            [[ -n "$img" ]] && all_images+=("$img")
        done <<< "$flux_images"
    else
        warn "Could not determine Flux images — skipping Flux pre-load"
    fi

    # Vault image — query tag from the Helm chart
    local vault_tag
    vault_tag=$(helm show values hashicorp/vault --version=0.30.1 2>/dev/null \
        | grep -A2 'image:' | grep 'tag:' | head -1 | awk '{print $2}' | tr -d '"')
    [[ -n "$vault_tag" ]] && all_images+=("hashicorp/vault:${vault_tag}")

    # ESO image — chart 0.19.2 ships image v0.19.2
    all_images+=("ghcr.io/external-secrets/external-secrets:v0.19.2")

    for img in "${all_images[@]}"; do
        info "Pulling $img → host cache..."
        docker pull "$img" || warn "Could not pull $img — will fall back to in-cluster pull"
        info "Loading $img → minikube (profile: $CLUSTER_NAME)..."
        minikube image load "$img" -p "$CLUSTER_NAME" || warn "Could not load $img into minikube"
    done

    success "Image pre-load complete"
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 1 — BOOTSTRAP-OWNED: Vault
# Changes here require re-running bootstrap.sh.
# ─────────────────────────────────────────────────────────────────────────────
install_vault() {
    section "Vault (bootstrap-owned)"
    local ns="${ENVIRONMENT}-vault"

    # Idempotency: skip if already running
    if kctl get pod -l app.kubernetes.io/name=vault -n "$ns" &>/dev/null; then
        local phase
        phase=$(kctl get pod -l app.kubernetes.io/name=vault -n "$ns" \
            -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
        if [[ "$phase" == "Running" ]]; then
            success "Vault already running — skipping install"
            return 0
        fi
    fi

    info "Installing Vault via Helm (dev mode — HTTP, auto-unseal, auto-init)..."
    kctl create namespace "$ns" --dry-run=client -o yaml | kctl apply -f -

    helm repo add hashicorp https://helm.releases.hashicorp.com --force-update
    helm upgrade --install "${ENVIRONMENT}-vault" hashicorp/vault \
        --namespace="$ns" \
        --version="0.30.1" \
        --set="global.tlsDisable=true" \
        --set="server.dev.enabled=true" \
        --set="server.dev.devRootToken=${VAULT_TOKEN}" \
        --set="server.dataStorage.enabled=true" \
        --set="server.dataStorage.size=1Gi" \
        --set="server.resources.requests.memory=128Mi" \
        --set="server.resources.requests.cpu=100m" \
        --set="server.resources.limits.memory=256Mi" \
        --set="server.resources.limits.cpu=200m" \
        --set="server.authDelegator.enabled=true" \
        --set="server.service.type=NodePort" \
        --set="injector.enabled=false" \
        --kube-context="$CLUSTER_NAME"

    info "Waiting for Vault pod..."
    sleep 3
    kctl wait --for=condition=ready pod -l app.kubernetes.io/name=vault \
        -n "$ns" --timeout=600s

    success "Vault installed"
}

configure_vault() {
    section "Vault configuration (bootstrap-owned)"
    local vault_url
    vault_url=$(get_vault_url)
    export VAULT_ADDR="$vault_url"
    export VAULT_TOKEN="$VAULT_TOKEN"

    info "Vault at: $vault_url"

    # ── KV v2 ──────────────────────────────────────────────────────────────
    if vault secrets list 2>/dev/null | grep -q "^secret/kubernetes"; then
        success "KV engine already configured — skipping"
    else
        info "Enabling KV v2 at secret/kubernetes..."
        # Remove the default secret/ mount so we can use secret/kubernetes
        vault secrets disable secret/ 2>/dev/null || true
        vault secrets enable -path=secret/kubernetes -version=2 kv
        success "KV v2 enabled at secret/kubernetes"
    fi

    # ── Demo secret ────────────────────────────────────────────────────────
    if vault kv get secret/kubernetes/hello/config &>/dev/null; then
        info "Demo secret already exists — skipping"
    else
        info "Writing demo secret..."
        vault kv put secret/kubernetes/hello/config \
            message="Hello from Vault"
        success "Demo secret written: secret/kubernetes/hello/config"
    fi

    # ── PKI ────────────────────────────────────────────────────────────────
    if vault secrets list 2>/dev/null | grep -q "^pki/" && vault read pki/ca/pem &>/dev/null; then
        success "PKI already configured — skipping"
    else
        info "Enabling PKI engine..."
        vault secrets enable -path=pki pki 2>/dev/null || true
        vault secrets tune -max-lease-ttl=87600h pki

        info "Importing CA certificate and key..."
        # Vault requires key before cert in the bundle
        vault write pki/config/ca \
            pem_bundle="$(cat "$REPO_ROOT/manual/certs/ca-key.pem" "$REPO_ROOT/manual/certs/ca-cert.pem")"

        info "Configuring PKI URLs..."
        vault write pki/config/urls \
            issuing_certificates="${vault_url}/v1/pki/ca" \
            crl_distribution_points="${vault_url}/v1/pki/crl"

        info "Creating cert-manager role (60-day window, ECDSA P-384)..."
        vault write "pki/roles/${NAMESPACE_PREFIX}-cert-manager" \
            allowed_domains="${CLUSTER_NAME}.lan,cluster.local" \
            allow_subdomains=true \
            allow_wildcard_certificates=true \
            max_ttl="1440h" \
            ttl="1440h" \
            key_type="ec" \
            key_bits=384 \
            server_flag=true \
            client_flag=false \
            require_cn=false

        info "Creating cert-manager policy..."
        vault policy write "${NAMESPACE_PREFIX}-cert-manager" - <<EOF
path "pki/sign/${NAMESPACE_PREFIX}-cert-manager" {
  capabilities = ["create", "update"]
}
path "pki/issue/${NAMESPACE_PREFIX}-cert-manager" {
  capabilities = ["create", "update"]
}
path "pki/ca/pem" {
  capabilities = ["read"]
}
EOF
        success "PKI configured"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 2 — BOOTSTRAP-OWNED: Kubernetes auth + ClusterSecretStore
# ClusterSecretStore is NOT in git — tied to Vault's auth config lifecycle.
# ─────────────────────────────────────────────────────────────────────────────
setup_kubernetes_auth() {
    section "Vault Kubernetes auth (bootstrap-owned)"
    local vault_url
    vault_url=$(get_vault_url)
    export VAULT_ADDR="$vault_url"
    export VAULT_TOKEN="$VAULT_TOKEN"

    if vault auth list 2>/dev/null | grep -q "kubernetes/" && \
       vault read "auth/kubernetes/role/external-secrets" &>/dev/null; then
        success "Kubernetes auth already configured — skipping"
        return 0
    fi

    info "Enabling Kubernetes auth method..."
    vault auth enable kubernetes 2>/dev/null || true

    # Create vault-auth service account for token review
    kctl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vault-auth
  namespace: ${ENVIRONMENT}-vault
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: vault-auth-delegator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
- kind: ServiceAccount
  name: vault-auth
  namespace: ${ENVIRONMENT}-vault
EOF

    sleep 2
    local sa_token ca_cert
    sa_token=$(kctl create token vault-auth -n "${ENVIRONMENT}-vault" --duration=8760h)
    ca_cert=$(kctl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d)

    vault write auth/kubernetes/config \
        kubernetes_host="https://kubernetes.default.svc.cluster.local" \
        kubernetes_ca_cert="$ca_cert" \
        token_reviewer_jwt="$sa_token"

    # ESO policy: read KV secrets
    vault policy write eso-policy - <<EOF
path "secret/kubernetes/data/*" {
  capabilities = ["read"]
}
path "secret/kubernetes/metadata/*" {
  capabilities = ["read"]
}
EOF

    # Auth role for ESO
    local k8s_issuer
    k8s_issuer=$(kctl get --raw /.well-known/openid-configuration 2>/dev/null \
        | grep -o '"issuer":"[^"]*"' | cut -d'"' -f4 \
        || echo "https://kubernetes.default.svc.cluster.local")

    vault write auth/kubernetes/role/external-secrets \
        bound_service_account_names=external-secrets \
        bound_service_account_namespaces=external-secrets-system \
        policies=eso-policy \
        audience="$k8s_issuer" \
        ttl=1h max_ttl=24h

    # Auth role for cert-manager
    vault write "auth/kubernetes/role/${NAMESPACE_PREFIX}-cert-manager" \
        bound_service_account_names="${NAMESPACE_PREFIX}-cert-manager" \
        bound_service_account_namespaces="${NAMESPACE_PREFIX}-cert-manager" \
        policies="${NAMESPACE_PREFIX}-cert-manager" \
        ttl=1h max_ttl=24h

    success "Kubernetes auth configured"
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 3 — ADOPTED BY FLUX: External Secrets Operator
# bootstrap.sh installs ESO here so Flux can sync secrets from Vault.
# Flux adopts the HelmRelease (infrastructure/base/external-secrets.yaml) for
# ongoing version management.
# ─────────────────────────────────────────────────────────────────────────────
install_eso() {
    section "ESO (adopted by Flux)"

    if kctl get deployment external-secrets -n external-secrets-system &>/dev/null; then
        local ready
        ready=$(kctl get deployment external-secrets -n external-secrets-system \
            -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        if [[ "${ready:-0}" -ge 1 ]]; then
            success "ESO already running — skipping install"
            create_clustersecretstore
            return 0
        fi
    fi

    info "Installing ESO via Helm (Flux will adopt this release)..."
    helm repo add external-secrets https://charts.external-secrets.io --force-update
    helm upgrade --install external-secrets external-secrets/external-secrets \
        --version 0.19.2 \
        --namespace external-secrets-system \
        --create-namespace \
        --set installCRDs=true \
        --set replicaCount=1 \
        --set resources.limits.cpu=100m \
        --set resources.limits.memory=128Mi \
        --set resources.requests.cpu=10m \
        --set resources.requests.memory=64Mi \
        --timeout=600s \
        --kube-context="$CLUSTER_NAME"

    info "Waiting for ESO..."
    sleep 10
    kctl wait --for=condition=available deployment external-secrets \
        -n external-secrets-system --timeout=600s

    # Wait for required CRDs
    for crd in clustersecretstores.external-secrets.io externalsecrets.external-secrets.io; do
        info "Waiting for CRD: $crd"
        local i=0
        until kctl get crd "$crd" &>/dev/null; do
            sleep 2; i=$((i+1)); [[ $i -lt 60 ]] || { error "Timeout waiting for $crd"; exit 1; }
        done
        success "CRD $crd ready"
    done

    success "ESO installed"
    create_clustersecretstore
}

create_clustersecretstore() {
    # ── BOOTSTRAP-OWNED: ClusterSecretStore ──────────────────────────────────
    # NOT in git — tied to Vault's Kubernetes auth configuration.
    # If Vault is re-initialized, this must be re-created.
    if kctl get clustersecretstore vault-backend &>/dev/null; then
        success "ClusterSecretStore vault-backend already exists — skipping"
        return 0
    fi

    local vault_internal="http://${ENVIRONMENT}-vault.${ENVIRONMENT}-vault.svc.cluster.local:8200"
    info "Creating ClusterSecretStore vault-backend (not in git)..."

    local attempts=3
    for ((i=1; i<=attempts; i++)); do
        if kctl apply -f - <<EOF
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: vault-backend
spec:
  provider:
    vault:
      server: "${vault_internal}"
      path: "secret/kubernetes"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "external-secrets"
          serviceAccountRef:
            name: "external-secrets"
            namespace: "external-secrets-system"
EOF
        then
            break
        fi
        if [[ $i -lt $attempts ]]; then
            warn "Retry $i/$attempts..."; sleep 10
        else
            error "Failed to create ClusterSecretStore"; exit 1
        fi
    done

    kctl wait --for=condition=Ready clustersecretstore vault-backend --timeout=60s
    success "ClusterSecretStore vault-backend ready"
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 4 — FLUX ENTRYPOINT: Install Flux + apply gotk-sync.yaml
# From here, Flux owns everything. The gotk-sync.yaml in git defines the rest.
# ─────────────────────────────────────────────────────────────────────────────
install_flux() {
    section "Flux (entrypoint)"

    if kctl get deployment helm-controller -n flux-system &>/dev/null; then
        success "Flux already installed — skipping"
    else
        info "Installing Flux controllers..."
        flux install --context="$CLUSTER_NAME"

        kctl wait --for=condition=ready pod -l app=helm-controller \
            -n flux-system --timeout=600s
        kctl wait --for=condition=ready pod -l app=kustomize-controller \
            -n flux-system --timeout=600s
        kctl wait --for=condition=ready pod -l app=source-controller \
            -n flux-system --timeout=600s
        success "Flux controllers ready"
    fi

    # GitHub auth secret — bootstrap-owned, never in git
    info "Creating GitHub auth secret for Flux..."
    kctl create secret generic flux-system \
        --namespace=flux-system \
        --from-literal=username="${GITHUB_USER:-git}" \
        --from-literal=password="${GITHUB_TOKEN}" \
        --dry-run=client -o yaml | kctl apply -f -
    success "GitHub auth secret created"

    # Apply gotk-sync.yaml from git with env var substitution.
    # ADOPTED BY FLUX: bootstrap creates GitRepository + root Kustomization
    # from the git-tracked template; Flux reconciles any future changes.
    if kctl get gitrepository jtate-vault-talk -n flux-system &>/dev/null; then
        success "GitRepository already exists — skipping"
    else
        info "Applying gotk-sync.yaml (Flux adopts from here)..."
        export GITHUB_BRANCH GITHUB_OWNER GITHUB_REPO
        envsubst < "$REPO_ROOT/clusters/dev/flux-system/gotk-sync.yaml" \
            | kctl apply -f -
        success "GitRepository + root Kustomization created"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────
main() {
    cd "$REPO_ROOT"
    info "Starting vault-talk demo bootstrap..."
    info "  Cluster: $CLUSTER_NAME  |  Branch: $GITHUB_BRANCH"

    check_prerequisites
    preload_images

    # ── BOOTSTRAP-OWNED ──────────────────────────────────────────────────────
    install_vault
    configure_vault
    setup_kubernetes_auth

    # ── ADOPTED BY FLUX ──────────────────────────────────────────────────────
    install_eso

    # ── FLUX ENTRYPOINT ──────────────────────────────────────────────────────
    install_flux

    echo ""
    success "Bootstrap complete!"
    echo ""
    info "Flux is now reconciling. Watch progress:"
    info "  flux get kustomizations --watch"
    info ""
    info "When apps is Ready, visit:"
    info "  https://hello.vault-talk.lan"
    info "  (run 'make add-hosts' if not done yet)"
    info ""
    info "Demo commands:"
    info "  kubectl get secret hello-message -n dev-hello -o yaml"
    info "  kubectl get secret hello-message -n dev-hello -o jsonpath='{.data.message}' | base64 -d"
    info "  vault kv put secret/kubernetes/hello/config message='Live update!'"
}

main
