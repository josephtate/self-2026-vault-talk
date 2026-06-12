---
marp: true
---
<!-- theme: default -->
<!-- class: invert -->
<!-- _class: lead invert -->

# Secure Secrets in Kubernetes
## Vault and the External Secrets Operator
### With a little FluxCD on the side

**Joseph Tate**
SELF 2026


---
# Secure Secrets in Kubernetes — Talk Outline

## 1. The Problem: Kubernetes Secrets Are Insecure by Default

- Secrets are base64-encoded ConfigMaps — not encrypted, just encoded
- No encryption at rest by default (etcd stores them in plaintext)
- No encryption in transit by default between etcd and the API server
- No access restriction by default — any workload in the namespace can read them
- RBAC *can* restrict access, but must be explicitly configured; the default is open
- "Secret" is a misleading name

## 2. The Solution: Vault + ESO + cert-manager

- HashiCorp Vault: encrypted secret storage, access policies, audit log, dynamic secrets
- External Secrets Operator: syncs Vault secrets into Kubernetes Secrets on a schedule
- cert-manager: automates TLS certificate issuance and renewal via Vault PKI

## 3. Separation of Concerns: Who Owns What

| Resource | Owned by | Why |
|---|---|---|
| Vault install + PKI config | bootstrap only | Stateful; imperative setup; Flux restarting it loses dev-mode data |
| `ClusterSecretStore vault-backend` | bootstrap only | Tied to Vault's K8s auth config; re-bootstrap required on change |
| GitHub auth secret | bootstrap only | Credentials — never in git |
| ESO HelmRelease | bootstrap → **Flux (adopted)** | Bootstrap installs first so Flux can sync secrets; Flux manages upgrades |
| `GitRepository` + root `Kustomization` | bootstrap → **Flux (adopted)** | Bootstrap applies from git template; Flux owns reconciliation |
| cert-manager, Traefik, ClusterIssuer | **Flux (pure)** | No bootstrap dependency |
| hello-world app (cert, secret, ingress) | **Flux (pure)** | Full app lifecycle via GitOps |

Key insight: `prune: false` on bootstrap-owned resources — they are intentionally absent from git.

## 4. Automated Certificate Rotation

- cert-manager requests 60-day certs from Vault PKI and auto-renews at 30 days remaining
- Illustrates the pattern: declare desired state, let the operator manage the lifecycle
- No manual intervention, no downtime, no forgotten renewals
- Same pattern applies to any operator managing stateful lifecycle (databases, message queues, etc.)

## 5. Production PKI vs. Demo CA

- This demo uses a self-signed CA generated locally (`make generate-ca`) and imported into Vault
- In production: Vault PKI is subordinate to your org's internal root CA (Vault never sees the root key)
- Alternatively: use a public CA (Let's Encrypt via ACME, DigiCert, etc.) — cert-manager supports both
- The Vault ClusterIssuer works identically either way; only the CA trust chain changes
- Key question for prod: who holds the root, and what's the rotation policy?

## 6. Live Demo: Secret Rotation in Real Time

```bash
# The secret is just base64 in Kubernetes
kubectl get secret hello-message -n dev-hello -o yaml

# Decode it
kubectl get secret hello-message -n dev-hello \
  -o jsonpath='{.data.message}' | base64 -d

# Update the source in Vault — ESO syncs within 30 seconds
vault kv put secret/kubernetes/hello/config message="Live update!"
kubectl get secret hello-message -n dev-hello \
  -o jsonpath='{.data.message}' | base64 -d
```

No pod restart. No deploy. The secret updated in place.
