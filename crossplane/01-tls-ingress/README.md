# TLS ingress example

The root app discovers `infra/tls-ingress`, which points at
`crossplane/01-tls-ingress`. Its Kustomization installs one ApplicationSet for
the TLS dependency group, generating two Applications:

Both generated Applications read `main` from
[`mujak27/crossplane-compilations`](https://github.com/mujak27/crossplane-compilations):

1. `tls-ingress-compositions`: path `01-tls-ingress`, selecting only `xrd.yaml`,
   `composition.yaml`, and `functions.yaml`.
2. `tls-ingress-xr`: path `01-tls-ingress/examples`, selecting `xr.yaml`.

Explicit, non-recursive directory selection prevents the definitions app from
including XR examples or rendering scripts. Update the include patterns when
adding files. The local `compositions/` and `xr/` scaffolds are no longer used.
Changes to the definitions/examples belong in the external repository; the
ApplicationSet and parent Application remain in this repository.

The current external XR example references the `app` Service on port 8080 and
the `letsencrypt-prod` ClusterIssuer. Those dependencies must exist in the cluster.

## Ordering and health

Apply `bootstrap/argocd` before syncing the parent. Its ConfigMap patch enables
ApplicationSet Progressive Syncs (beta in the pinned Argo CD version). On an
existing installation, restart `argocd-applicationset-controller` after applying
the config so it reloads the environment setting.

RollingSync selects generated Applications using `k8s-crossplane/stage`:
sync compositions first, wait for that app to become Healthy, then sync XRs.
It handles initial and later OutOfSync rollouts; individual child auto-sync is
intentionally absent. No Application-level Lua health customization is needed.
These labels are our own selectors, not Crossplane features.

Application health still depends on Argo's health checks for the resources it
contains. Verify coverage for the actual XRDs, providers, functions, and XR types
before treating Healthy as proof of readiness. Ensure Crossplane and its required
packages are ready before adding XRs. Manual child syncs bypass this ordering.

## Independent dependency groups

For a database or storage group, create a separate directory and ApplicationSet
with its own name, generated app names, and source paths. Register a corresponding
parent Application in `infra/`. Each set runs its own compositions-to-XR steps:

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

Applications track `main`, matching the rest of the repository; merge this
branch before deployment (or change all relevant revisions for branch testing).
Generated syncs do not enable pruning. `preserveResourcesOnDeletion: true` keeps
ApplicationSet-generated apps from receiving resource-deletion finalizers;
deleting the set can delete its Applications but preserves deployed resources.
