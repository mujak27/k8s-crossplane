# TLS ingress with the GHCR custom function

This is additive: the original `XIngressTLS` and `app.mujak.com` remain unchanged.
The root includes `crossplane/kustomization.yaml` via `infra`, enabling the parent
`crossplane/02-tls-ingress-custom/application.yaml`. It installs a separate
ApplicationSet with the existing compositions-to-XR RollingSync pattern:

```text
crossplane-shared: function-tls-ingress v0.1.2
tls-ingress-custom-compositions: XRD + Composition + aggregate RBAC
  -> tls-ingress-custom-xr: default/nginx-custom
```

Both generated Applications read this repository's `main` and use Kustomize.
The compositions layer imports the upstream definitions-only Kustomize base at
[`tls-ingress-custom-v0.1.0`](https://github.com/mujak27/crossplane-compilations/releases/tag/tls-ingress-custom-v0.1.0).
It contains the independent `XIngressTLSCustom` XRD and Composition, including
the `Expired` health enum value. The Argo CD repo-server must be able to fetch
the GitHub base. Functions and upstream example XRs are not imported.
Definitions and the Function package are released separately; no new runtime
package is needed for this definitions release.

The shared Functions app owns `ghcr.io/mujak27/function-tls-ingress:v0.1.2`.
Release tag `function-tls-ingress-v0.1.2` points to
`c5623438dfbbf35ff50fd79612d64fe9996bf69f`; the anonymously verified package
digest is `sha256:b6feffca55f78a2a317cb8431d0eaafab2609137a813ac8719fd12590bb2d2d6`
([successful release workflow](https://github.com/mujak27/crossplane-compilations/actions/runs/38611128462)).
The release was built for **linux/amd64**. Validate the target cluster's runtime
compatibility before rollout; node architecture alone does not establish whether
cross-architecture emulation is available. The custom aggregate
ClusterRole grants native Certificate/Ingress permissions without taking ownership
of the original example's role. Functions, XRDs, Compositions and ClusterRoles are
cluster-scoped; the XR and composed resources are namespaced.

## Rollout prerequisites

- Merge before deployment: all Applications track `main`.
- Ensure Crossplane, cert-manager and the NGINX ingress controller are ready.
- Sync `crossplane-shared` and verify `function-tls-ingress` is Installed and Healthy
  before syncing the custom group. Parent sync waves only order app creation;
  they do not gate Function readiness.
- Enable Progressive Syncs via `bootstrap/argocd`, as described in
  `../01-tls-ingress/README.md`. RollingSync waits for compositions app health
  before syncing XRs; verify Argo health coverage and XRD establishment, rather
  than assuming Application Healthy proves all dependencies ready.
- Provide the existing `default/app` Service on port **80** and ready
  `selfsigned-ca` ClusterIssuer from the private GitOps repository.
- Point `app-custom.mujak.com` at the NGINX ingress endpoint. Clients must trust
  the private CA; this uses the existing private issuer, not ACME.

The XR creates Certificate and Ingress `default/nginx-custom` and uses Secret
`default/nginx-custom-tls`. Its distinct name and hostname avoid collisions with
the original XR. The function does not create the backend Service or issuer.
No auto-ready step is added. The custom function considers provisioning ready when
the Certificate is Ready=True for its current generation with a valid future
expiry, and the observed Ingress matches its desired configuration. An empty
Ingress load-balancer status is acceptable; it does not gate provisioning
readiness. HTTPS trust and backend connectivity are separate traffic checks and
must be reported independently, even when the XR is ready.

Rollback by restoring the previous immutable Function pin
`ghcr.io/mujak27/function-tls-ingress:v0.1.0`; this restores the previous
readiness behavior. Do not test rollback without approval.

Pruning and resource-deletion finalizers remain disabled. Removing these apps
does not remove deployed resources; clean up explicitly if retiring the example.
No cluster deployment was performed as part of this change. Live rollout requires
explicit approval and verification of runtime compatibility on the target cluster.

## Local validation

```sh
kubectl kustomize infra
kubectl kustomize crossplane/_shared
kubectl kustomize crossplane/02-tls-ingress-custom
kubectl kustomize crossplane/02-tls-ingress-custom/compositions
kubectl kustomize crossplane/02-tls-ingress-custom/xr
```
