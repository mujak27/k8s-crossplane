# TLS ingress example

The root app includes `crossplane/kustomization.yaml` via `infra`, which enables
`crossplane/01-tls-ingress/application.yaml`. That parent points at
`crossplane/01-tls-ingress`. Its Kustomization installs one ApplicationSet for
the TLS dependency group, generating two Applications:

The generated Applications use separate repositories and revisions:

1. `tls-ingress-compositions`: repository
   [`mujak27/crossplane-compilations`](https://github.com/mujak27/crossplane-compilations),
   path `01-tls-ingress`, selecting only `xrd.yaml`, `composition.yaml`,
   and `rbac.yaml`. The RBAC grants Crossplane permission to
   manage the composed Certificates and Ingresses. Its reviewed revision is
   `34640c4c65119295e75ffab660759bc9ea3b0b3e`.
2. `tls-ingress-xr`: repository
   [`mujak27/k8s-crossplane`](https://github.com/mujak27/k8s-crossplane),
   path `crossplane/01-tls-ingress/xr`, selecting `xr.yaml`.

Explicit, non-recursive directory selection prevents the definitions app from
including XR examples or rendering scripts. Update the include patterns when
adding files. The local `compositions/` scaffold is not used. Manage XR instances
in this repository's `xr/` directory; changes to the reusable definitions belong
in the external repository. The ApplicationSet and parent Application also remain
in this repository. The XR Kustomization supports local rendering, while Argo CD
uses the explicit directory include above.

The local XR references the `app` Service on port 8080 and
the `selfsigned-ca` ClusterIssuer managed by `k8s-crossplane-private` under
`infra/selfsigned/resources`. That issuer signs application certificates using
the root CA created by `selfsigned-bootstrap`. The Service and ready issuer must
exist in the cluster; clients must trust the private root CA.

### Updating the upstream definitions pin

To update the definitions revision, review the exact upstream commit's
`01-tls-ingress/xrd.yaml`, `composition.yaml`, and `rbac.yaml` against the
currently declared upstream snapshot, including the XRD contract, composed
resources, and permissions. Record the selected full commit SHA and material differences
in this document and the change review, then update only the `compositions`
element's `targetRevision` above. Validate the candidate XR against that exact
commit's XRD and inspect/render the declared definitions before rollout. Keep
the `xr` element on this repository's revision; do not copy upstream
definitions into the local `compositions/` scaffold or change that scaffold's
empty Kustomization. Roll out the reviewed change through the normal GitOps
review process; do not advance the pin by following upstream `main`.

The selected snapshot was upstream `main` at review time on 2026-10-27 UTC,
commit `34640c4c65119295e75ffab660759bc9ea3b0b3e`. Compared with the prior
`tls-ingress-custom-v0.1.0` tagged snapshot, its XRD and RBAC are unchanged.
Its Composition intentionally adds current-generation Certificate readiness
checks, ingress-shape readiness checks, and certificate expiry health
reporting; these upstream changes are retained as the content already selected
by the declared upstream `main` source at review time, not introduced as local
policy. This review did not inspect or confirm a live cluster's deployed
revision.

## Ordering and health

Shared Functions are managed separately by the `crossplane-shared` Application,
registered in `crossplane/_shared/application.yaml` and sourced from
`crossplane/_shared`.
The TLS compositions Application no longer selects the external `functions.yaml`.
The shared app has sync wave 0, between Crossplane (-10) and the TLS parent (10).
These waves order Application creation, not package readiness; ensure both shared
Functions are installed and Healthy before relying on TLS compositions or XRs.
When migrating an existing installation, update the TLS compositions app's source
selection without pruning, then sync `crossplane-shared` to take ownership of the
existing Functions. Do not prune the Functions from the old app.

Apply `bootstrap/argocd` before syncing the parent. Its ConfigMap patch enables
ApplicationSet Progressive Syncs (beta in the pinned Argo CD version). On an
existing installation, restart `argocd-applicationset-controller` after applying
the config so it reloads the environment setting.

RollingSync selects generated Applications using `k8s-crossplane/stage`:
the controller automatically syncs compositions first, waits for that app to
become Healthy, then syncs XRs. It handles initial and later OutOfSync rollouts;
individual child auto-sync is intentionally absent, not a requirement for human
sync. No Application-level Lua health customization is needed.
These labels are our own selectors, not Crossplane features.

Application health still depends on Argo's health checks for the resources it
contains. Verify coverage for the actual XRDs, providers, functions, and XR types
before treating Healthy as proof of readiness. Ensure Crossplane and its required
packages are ready before relying on XRs. Manual child syncs bypass this ordering.
Live commands still need explicit authorization; automation does not replace
runtime and TLS checks.

## Independent dependency groups

For a database or storage group, create a separate directory and ApplicationSet
with its own name, generated app names, and source paths. Register a corresponding
parent `application.yaml` in that project's directory, enabled through
`crossplane/kustomization.yaml`. Each set runs its own compositions-to-XR steps:

```text
TLS ApplicationSet:      TLS compositions      -> TLS XRs
Database ApplicationSet: database compositions -> database XRs
```

Do not combine unrelated compositions in this set's first step: one unhealthy
Application blocks subsequent steps in the same set. The dependency-group label
documents membership; isolation comes from separate ApplicationSets. There is
no automatic discovery of XR-to-XRD dependencies.

## Migration from the two standalone Applications

The generated Application names are unchanged. If the old Applications already
exist, verify the ApplicationSet has adopted them and removed their automated
sync policies before relying on RollingSync. Pruning is disabled, so an existing
`resource.customizations.health.argoproj.io_Application` key may remain in
`argocd-cm`; remove that obsolete key explicitly after migration.

The XR Application tracks this repository's `main`; the definitions Application
uses the reviewed immutable upstream commit above. Merge this branch before
deployment (or change the relevant repository revision for branch testing).
Generated syncs do not enable pruning. `preserveResourcesOnDeletion: true` keeps
ApplicationSet-generated apps from receiving resource-deletion finalizers;
deleting the set can delete its Applications but preserves deployed resources.
