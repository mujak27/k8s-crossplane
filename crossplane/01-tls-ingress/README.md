# TLS ingress example

The root app discovers `infra/tls-ingress`, which points an app-of-apps at
`crossplane/01-tls-ingress`. That parent creates two child Applications:

1. `tls-ingress-compositions` (wave 0): `compositions/` holds XRDs, Compositions,
   and any required Crossplane package/configuration manifests.
2. `tls-ingress-xr` (wave 10): `xr/` holds example composite resources.

Both directories are empty scaffolds. Add manifests to each directory and list
them in its `kustomization.yaml`; no TLS composition or XR is supplied yet.

Apply `bootstrap/argocd` before syncing the parent. Its Application health
customization makes the parent wait until the composition app is **Synced and
Healthy** before creating the XR app. Only Applications labelled
`k8s-crossplane/sync-gate: "true"` are gated; unrelated infrastructure retains
its existing behavior. Ensure Crossplane and its required providers
and functions are installed and healthy before introducing XRs.

Sync waves gate initial creation, not later independent auto-syncs of existing
children. For changes that introduce a new XR API, first merge/sync definitions
and wait for readiness, then merge the XR examples separately.

Applications track `main`, matching the rest of the repository; merge this
branch before deployment (or change all relevant revisions for branch testing).
Pruning is disabled, matching the existing infrastructure apps.
