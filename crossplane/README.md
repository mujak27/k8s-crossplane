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
```

## Enabling projects

Add `application.yaml` to the project's directory and reference that file
directly in `crossplane/kustomization.yaml`. Give the project its own directory and
ApplicationSet, with compositions-to-XR RollingSync when needed. Preserve
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
kubectl kustomize crossplane
kubectl kustomize infra
kubectl kustomize crossplane/_shared
kubectl kustomize crossplane/02-tls-ingress-custom/compositions
kubectl kustomize crossplane/02-tls-ingress-custom/xr
```

Registry inclusion and parent sync waves order app creation, not Crossplane or
Function readiness. Follow each project's rollout prerequisites before syncing
its XRs. Directory consolidation improves locality; it does not change runtime
dependency guarantees.
