# Crossplane GitOps convention

All Crossplane-owned manifests live under `crossplane/`: the controller's Argo
Application, shared Functions, project parent Applications, ApplicationSets,
definitions or references to them, RBAC and XR instances. Other infrastructure
such as cert-manager and ingress controllers stays under `infra/`.

```text
infra/kustomization.yaml
  -> ../crossplane
     kustomization.yaml       # registry of enabled Crossplane Applications
     _controller/             # controller Application
     _shared/                 # Application + shared Function packages
     01-tls-ingress/           # Application + ApplicationSet + original XR
     02-tls-ingress-custom/    # Application + ApplicationSet + definitions + XR
     03-istio-secure-egress/   # definitions/profile/RBAC + XR + gated HTTP client
```

## Enabling projects

Add `application.yaml` to the project's directory and reference that file
directly in `crossplane/kustomization.yaml`. Give the project its own directory and
ApplicationSet, with automated child sync and the default AllAtOnce strategy. Preserve
separate ownership of shared Functions in `_shared/`.

The registry renders **Applications only**, not every project's resources.
Do not add project workload directories or `_shared/` directly to it: doing so
would bypass their Applications, flatten dependency ordering and create duplicate
Argo ownership. `infra/` has just one reference to the Crossplane registry.

Keep each directory's workload Kustomization separate: it must not include its
own parent `application.yaml`, or the parent would manage itself. The top-level
registry selects the Application file; the Application selects the directory's
workload Kustomization.

Application names, source paths and sync waves do not change when colocating their
manifest files with their projects. This keeps the existing apps and their
tracked workloads intact. No pruning or deletion finalizers are enabled.
Removing an entry stops declaring the Application, but with pruning disabled
the existing Application remains and can keep managing its workloads. Retiring
a project requires explicitly deleting its Applications without cascading;
deployed resources still require explicit cleanup.

## Version convention

- Pin Function packages to an explicit published version, not `latest`.
- Pin reusable definitions to a Git commit or a release tag containing the
  intended XRD and Composition. Avoid `main` for pinned definition overlays.
- Prefer readable release tags when available; treat them as immutable by
  convention. Commit hashes identify exact source content, whereas tags can
  be moved. Package tags can also be overwritten unless the publisher prevents it.
- Function package versions and definition refs need not be identical: a source
  schema fix may follow the package release without changing function behavior.
- Update all references to a definition release together and render the result.
  Verify XR kinds, Composition selection and schema compatibility.

Kustomize `resources` URLs are literal strings. YAML anchors cannot interpolate
part of a URL or share values across files, and Kustomize replacements do not
rewrite remote resource URLs before fetching them. For a few files, repeating
the pinned ref is preferable to adding a templating or generation tool.
When upstream publishes a dedicated Kustomize base, one Git base URL with
`?ref=<tag-or-commit>` can select the whole release using a single reference.
That requires an upstream `kustomization.yaml` selecting definitions only;
the custom example uses this form at `tls-ingress-custom-v0.1.0`.

## Validation and rollout

```sh
ruby validate-sync.rb /path/to/k8s-crossplane-private
kubectl kustomize crossplane
kubectl kustomize infra
kubectl kustomize crossplane/_shared
kubectl kustomize crossplane/02-tls-ingress-custom/compositions
kubectl kustomize crossplane/02-tls-ingress-custom/xr
ruby crossplane/03-istio-secure-egress/validate-platform.rb
ruby crossplane/03-istio-secure-egress/validate-trust.rb
ruby crossplane/03-istio-secure-egress/validate.rb --render
```

Registry inclusion and parent sync waves order app creation, not Crossplane or
Function readiness. All declared Applications now auto-sync without pruning;
RollingSync was removed because it forcibly disables child auto-sync. Newly
automated apps retry failed syncs indefinitely with 5s exponential backoff capped
at 3m, following the private selfsigned policy. Independent reconciliation can
race CRDs, webhooks, namespaces and Functions. Retry is not a readiness guarantee:
admission failures and unhealthy dependencies require observation and recovery.
Follow each project's runtime/TLS/security gates; the secure-egress client stays
suspended until an explicitly authorized operator resumes it. Automation policy
does not authorize agents to run live sync, resume or other mutation commands.

### Secure-egress Function runtime gate

`_shared/functions.yaml` is the sole installation owner of
`ghcr.io/mujak27/function-istio-secure-egress:v0.1.0`; its published manifest
digest is recorded beside the version pin. Do not install another copy in a
project or commit CLI-only Development runtime annotations.

This released package is **linux/amd64 only**, while the intended OrbStack node
is **linux/arm64**. Execution of this exact package must be observed, not inferred
from other healthy Functions. The target runs Crossplane **2.4.2**, whereas
upstream testing used **2.5.0**; required-resources and full XR reconciliation on
the target remain unproven until separately validated live. Local Kustomize
renders prove neither runtime compatibility nor reconciliation.

Before deploying dependent XRs, an explicitly authorized operator must check the
exact package digest, pull/start behavior and Function Installed/Healthy
conditions on the target. A pull failure, execution error or unhealthy runtime
is a hard stop: record evidence and obtain a new decision. Do not substitute a
package, rebuild, configure emulation, alter registry credentials or upgrade
Crossplane to get past this gate. A healthy Function alone does not prove full
XR reconciliation or the demo's TLS/traffic path.

Authorized startup observation on 2026-10-22 (context `orbstack`, API server
`https://127.0.0.1:26443`, node `orbstack`, Kubernetes `v1.36.5+orb1`,
linux/arm64, Crossplane `v2.4.2`): Function Installed and Healthy were both True
at 12:40:36Z. Revision `function-istio-secure-egress-a31cd510428b` reported
RuntimeHealthy, RevisionHealthy and RuntimeActive True; its runtime pod was
Running/Ready with zero restarts and imageID matching the recorded published
digest. The image was already cached on the node, so fresh registry pull/auth
was not exercised. No emulation setup or runtime modification was performed.
This establishes exact-package startup/health on this target only; it does not
establish portable ARM64 support, required-resources execution, or XR
reconciliation. Recheck health and the remaining gates before dependent rollout.

The secure-egress project's local validators also passed on 2026-10-22, including
actual released-package output with the local CLI v2.5.0 and explicitly selected
Crossplane v2.4.2 Docker render engine. This confirms the local four-resource
output contract with supplied EnvironmentConfig, not target-cluster
required-resources execution or full XR reconciliation. The enabled XR and
suspended HTTP client have separate ownership; only an authorized operator may
resume the client after the [project rollout gates](03-istio-secure-egress/README.md).
Live TLS, negative SAN/CA cases and gateway-traversal acceptance remain unproven.
