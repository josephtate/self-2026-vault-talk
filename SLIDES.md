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

## The Problem: Kubernetes Secrets Are Insecure by Default

- Secrets are encoded, not encrypted
- Secrets are not encrypted at rest
- Secrets can be read by any workload in the namespace
- "Secret" is a misleading name

<!--
- Secrets are base64-encoded — not encrypted, like a ConfigMap with an extra step
- No encryption at rest by default (etcd stores them in plaintext)
- No access restriction by default — any workload in the namespace can read them
- RBAC *can* restrict access, but must be explicitly configured; the default is open
-->

---

## The Solution: Vault + ESO + cert-manager

- Vault by HashiCorp is the leading tool for secure secret management
  - Use OpenBao for an OSS fork
- ESO allows Vault secrets to be used like K8s Secrets
- cert-manager handles issuing and renewing certificates through Vault and other CAs

<!--
- HashiCorp Vault: encrypted secret storage, access policies, audit log, dynamic secrets
- External Secrets Operator: syncs Vault secrets into Kubernetes Secrets on a schedule
- cert-manager: automates TLS certificate issuance and renewal via Vault PKI
-->

---

### Caveats:

- K8s still has a copy of the secret
- ExternalSecrets still need RBAC
- Synced secrets are still plaintext in memory
- etcd must be secured anyway

---

### Benefits:

- Secrets never touch source control
- Centralized lifecycle management
- Strong auditing
- Dynamic/short-lived credentials
- Limited blast radius on breach

<!-- So why bother? -->
---

## Separation of Concerns: Who Owns What?

- What does provisioning?
- What does deployment?
- What does configuration management?
- What does secret lifecycle management?

### Use the best tool for the job

---

## Separation of Concerns: Examples

| Resource | Owned by | Why |
|---|---|---|
| Vault install + PKI config | External | Shared resource |
| `ClusterSecretStore vault-backend` | External | Tied to Vault's K8s auth config, details not known to K8s team |
| GitHub auth secret | Stored in Vault | Credentials — never in git |
| GitHub ExternalSecret | FluxCD (pure or adopted) | No actual secret data, part of Config Mgmt|
| ESO HelmRelease | Externally Created → **Flux (adopted)** | Catch-22; required by Flux install, Flux manages |

---

## Separation of Concerns: Examples Continued

| Resource | Owned by | Why |
|---|---|---|
| `GitRepository` + root `Kustomization` | Created before Flux install → **Flux (adopted)** | Using an external secret with this resource is another Catch-22 |
| cert-manager, Traefik, ClusterIssuer | **Flux (pure)** | No actual secrets, no catch-22 |
| hello-world app (cert, secret, ingress) | **Flux (pure)** | Full app lifecycle via GitOps |

### External Resources are invisible to Flux unless adopted.

<!-- `prune: true` has no effect on external Resources during reconciliation -->

---

## Automated Certificate Rotation

- We configure cert-manager to create 60-day certs from Vault PKI and auto-renew at 30 days remaining
- No manual intervention, no downtime, no forgotten renewals

<!--
Vault supports the ACME protocol well enough for cert-manager to request and renew certs. This is not the only way; you can also manually create certs with a 3rd party registrar, but our demo today is self-contained
-->

---

## Production PKI vs. Demo CA

- We use a self-signed CA for LAN-accessible hosts
- Use Let's Encrypt or a Commercial CA for public ingress depending on requirements
- Customize for your needs

<!--
- This demo uses a self-signed CA generated locally (`make generate-ca`) and imported into Vault
- In production: Vault PKI is subordinate to your org's internal root CA (Vault never sees the root key)
- Alternatively: use a public CA (Let's Encrypt via ACME, DigiCert, etc.) — cert-manager supports both
- The Vault ClusterIssuer works identically either way; only the CA trust chain changes
- Key question for prod: who holds the root, and what's the rotation policy?
-->

---

## Live Demo: Secret Rotation in Real Time

```bash
# The secret is just base64 in Kubernetes
kubectl get secret hello-message -n dev-hello -o yaml

# Decode it
kubectl get secret hello-message -n dev-hello \
  -o jsonpath='{.data.message}' | base64 -d

# Update the source in Vault — ESO configured to sync every 30 seconds
vault kv put secret/kubernetes/hello/config message='Live update!'
kubectl get secret hello-message -n dev-hello \
  -o jsonpath='{.data.message}' | base64 -d
```

No pod restart. No deploy. The secret updated in place.

---

# Questions?

_Continuous Deployment + GitOps: my next talk at 2PM_

https://github.com/josephtate/self-2026-vault-talk
