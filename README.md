# Vault Talk Demo Repo

Demo repository for the talk **"Secure Secrets in Kubernetes"** — showing how to use HashiCorp Vault, External Secrets Operator, and cert-manager to replace plain K8s Secrets with properly managed, automatically rotated credentials and TLS certificates.

## Pre-Talk Setup (~30 min before)

```bash
make minikube-start   # start a local cluster
make generate-ca      # create a demo CA (gitignored)
make trust-ca         # install CA into system trust store
make add-hosts        # add hello.vault-talk.lan to /etc/hosts
```

Then push this repo to GitHub (or fork it) and set:
```bash
export GITHUB_OWNER=<your-org-or-user>
export GITHUB_TOKEN=<github-pat-with-repo-read>
```

## Live Demo

```bash
make bootstrap-dev
flux get kustomizations --watch
# then open https://hello.vault-talk.lan in a browser
```

## Ownership Model

This demo highlights the boundary between **bootstrap** infrastructure and **GitOps-managed** resources.

| Resource | Created by | Managed by | Reason |
|---|---|---|---|
| Vault HelmRelease + PKI config | `bootstrap.sh` | bootstrap only | Stateful; imperative PKI setup; Flux touching it risks data loss in dev mode |
| `ClusterSecretStore vault-backend` | `bootstrap.sh` | bootstrap only | Tied to Vault K8s auth; changes require re-bootstrap |
| GitHub auth secret `flux-system` | `bootstrap.sh` | bootstrap only | Credentials — never in git |
| ESO HelmRelease | `bootstrap.sh` first, then Flux | **Flux (adopted)** | Bootstrap installs ESO so Flux can sync secrets; Flux takes over upgrades |
| `GitRepository` + root `Kustomization` | `bootstrap.sh` (from git template) | **Flux (adopted)** | Bootstrap applies the git-tracked template; Flux manages ongoing reconciliation |
| cert-manager HelmRelease | Flux | **Flux (pure)** | No bootstrap dependency |
| Traefik HelmRelease | Flux | **Flux (pure)** | No bootstrap dependency |
| `ClusterIssuer vault-issuer-dev` | Flux | **Flux (pure)** | cert-manager CRD resource |
| hello-world app (cert, secret, ingress) | Flux | **Flux (pure)** | Full app lifecycle via GitOps |

Key insight: `prune: false` on bootstrap-owned resources would remove them if they were in git — they're intentionally not.

## What Flux Manages

```
flux-system (Flux manages itself)
     ↓
infrastructure   (ESO adopted, cert-manager + Traefik installed)
     ↓ dependsOn
helmresources    (ClusterIssuer — needs cert-manager CRDs)
     ↓ dependsOn
apps             (hello-world: Certificate, ExternalSecret, IngressRoute)
```

## Demo: K8s Secrets Are Just Base64

```bash
# The secret synced from Vault is just base64 in Kubernetes
kubectl get secret hello-message -n dev-hello -o yaml

# Decode it
kubectl get secret hello-message -n dev-hello \
  -o jsonpath='{.data.message}' | base64 -d

# Update in Vault — ESO syncs within 30s
vault kv put secret/kubernetes/hello/config message="Live update!"
kubectl get secret hello-message -n dev-hello \
  -o jsonpath='{.data.message}' | base64 -d
```

## Certificate Rotation

cert-manager issues 60-day TLS certificates from Vault PKI and automatically renews at 30 days remaining. No manual intervention, no outage.

```bash
kubectl get certificate -n dev-hello
kubectl describe certificate hello-cert-dev -n dev-hello
```
