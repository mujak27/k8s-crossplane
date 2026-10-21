---
name: deploy-crossplane-function
description: Deploy a custom Crossplane function into this GitOps repository from published packages and pinned upstream definitions. Use when adding or deploying a new custom function project, its shared Function, RBAC, XR, or Argo CD wiring.
---

# Deploy a Crossplane function

This skill supplies the Crossplane contract, wiring, rollout, and validation to
`plan-to-tickets`. Load that coordinator and follow its worktree, design/plan,
ticket, and implementation gates; keep orchestration there.

Deployment consumes published Function packages and published upstream
definitions. Authoring or publishing a function is out of scope. Missing
artifacts stop the work.

## 1. Fix the deployment contract

Record before creating files:

- Upstream repository: default `mujak27/crossplane-compilations`. Use another
  only when the user explicitly requests it; record that request.
- Project ID and upstream path: drop the numeric prefix
  (`02-tls-ingress-custom` becomes `tls-ingress-custom`).
- Definitions ref: a release tag (preferred) or commit whose base contains the
  intended XRD and Composition. `main` is the legacy source, not a pin.
- Function package: a published image and explicit version, never `latest`.
- Architecture and prerequisites: package architecture, Crossplane version,
  required providers or controllers, and the XR namespace.
- Compatibility: package and definitions releases may differ. Read the pinned
  XRD/Composition and the package release notes to confirm the fields and
  behavior the Composition expects.

Verify the pinned base is definitions-only: its `kustomization.yaml` selects
the XRD and Composition, not Functions, example XRs, render scripts, or RBAC.
Confirm the tag resolves to the intended commit and the package version is
published.

If the package, pin, or definitions-only base is missing, stop and report the
exact missing artifact. Do not invent a pin, import individual upstream files
from `main` as legacy `01-tls-ingress` does, or begin upstream authoring.

**Done:** contract recorded with exact immutable refs and verified contents, or
a precise blocker report.

## 2. Check identities and contracts

- XRD identity is `<plural>.<group>`; kind, plural, group, and served version
  must match the Composition and XR.
- Composition names are unique cluster-wide. Preserve existing names; new
  projects use `<project-id>.<group>`.
- XR schema and required fields come from the pinned XRD, including health
  enums the function emits.
- Crossplane v2 XR uses `spec.crossplane.compositionRef` to select the
  Composition explicitly. XRs and composed resources are namespaced; XRDs,
  Compositions, Functions, and aggregate ClusterRoles are cluster-scoped.
- Names collide across kinds in one namespace: XR name, composed resource
  names, hostnames, and Secrets. A new kind does not isolate them.
- List the composed kinds the pinned Composition and function documentation
  actually render; a pipeline-only Composition can hide them inside the
  function. Do not assume every function composes Ingress or Certificate
  resources.
- Readiness is function-specific: derive it from the composition logic and
  external resources. Some functions implement no readiness detector. Do not
  add auto-ready unless the contract needs it.

**Done:** every identity, selected Composition, required field, collision,
composed kind, and readiness condition is traced to the pinned artifacts.

## 3. Wire the 02 pattern

Create `crossplane/<NN>-<project-id>/`:

- `application.yaml`: parent Application, no deletion finalizer, sync wave 10,
  source path the project directory, automated sync with pruning disabled.
- `applicationset.yaml`: `compositions` then `xr` list stages, RollingSync with
  `maxUpdate: 1`, `preserveResourcesOnDeletion: true`, generated Applications
  without automated sync, `ServerSideApply=true`.
- `kustomization.yaml`: selects `applicationset.yaml` only, never the parent
  Application or workload directories.
- `compositions/kustomization.yaml`: pinned upstream definitions base plus local
  `rbac.yaml`.
- `compositions/rbac.yaml`: only the permissions the Composition needs,
  aggregated to Crossplane, with a project-owned ClusterRole name. Check
  existing roles and ownership first; do not take over an upstream role.
- `xr/`: local Kustomization and one XR with explicit `compositionRef`.

Shared Functions:

- Declare each Function once in `crossplane/_shared/functions.yaml` at a
  published version.
- Reuse an existing declaration for the same function instead of duplicating
  it per project.
- A new declaration is a shared dependency change; note its rollout order.

Registry and ownership:

- Add only `<NN>-<project-id>/application.yaml` to
  `crossplane/kustomization.yaml`; never project or workload directories, and
  never `_shared/`.
- Keep the single `infra` reference to the registry. The parent must not manage
  itself, and the registry must not flatten workloads into Argo ownership.
- Leave `01-tls-ingress` and `02-tls-ingress-custom` byte-for-byte unchanged.

**Done:** the project renders standalone and the registry adds exactly one
Application reference.

## 4. Validate locally

Use the checks the repository supports:

```sh
kubectl kustomize crossplane
kubectl kustomize infra
kubectl kustomize crossplane/_shared
kubectl kustomize crossplane/<NN>-<project-id>
kubectl kustomize crossplane/<NN>-<project-id>/compositions
kubectl kustomize crossplane/<NN>-<project-id>/xr
```

Inspect:

- Registry: Applications only; exactly one new Application; no workloads or
  self-managed parent.
- Shared: one declaration per Function, published versions, no duplicate
  owners.
- Project: the ApplicationSet only; the parent Application is not selected by
  the workload Kustomization.
- Definitions: exact pinned ref in `compositions/kustomization.yaml`; XRD and
  Composition kinds only; no upstream Functions, examples, or RBAC.
- XR: kind, version, and namespace match the XRD; `compositionRef` names the
  pinned Composition; required fields are present.
- Ownership: no duplicate Application names, Function declarations, or
  ClusterRoles.

Rendering fetches the remote base, so it needs network access; a fetch failure
is a reported failure, not a reason to change refs. Rendering proves file
assembly only. It does not validate OpenAPI schema, Crossplane runtime behavior,
function architecture, RBAC sufficiency, or cluster readiness. Report passed,
failed, skipped, and unavailable checks separately, and never imply live
cluster verification.

**Done:** every listed render ran and was inspected, or its unavailability is
reported.

## 5. Hand off rollout and rollback

Ordering is not readiness:

- Parent sync waves and RollingSync order Application creation only. They do
  not prove Function health, XRD establishment, RBAC effectiveness, or
  composed resource readiness.
- Sync `crossplane-shared` and verify the Function package is Installed and
  Healthy before syncing XRs. Confirm the XRD is Established and the
  Composition is selected. Check function-specific prerequisites such as an
  issuer, ingress, gateway, or backend service separately.
- Verify Argo health coverage for the XR kind before treating Application
  Healthy as readiness. Provisioning readiness does not prove traffic, TLS, or
  network health; verify those separately.

Permissions:

- Planning, plan approval, ticket publication, and this skill's invocation do
  not authorize implementation, push, or PR creation.
- In authorized implementation, pushing the task branch and opening a PR are
  allowed. Merge, live sync, delete, cleanup, and other cluster mutations each
  need explicit approval. A merge can trigger GitOps reconciliation.
- At the breakdown checkpoint, ask the user to invoke `to-tickets`; user-only
  companions stay with the user.

Rollback and retirement:

- Pruning is disabled. Removing a registry entry or declaration deletes neither
  the Application nor its resources.
- Retiring a project needs explicit non-cascading Application deletion and
  explicit resource cleanup, with approval.
- Rollback restores the previous immutable Function and definitions pins. It
  does not guarantee removal of resources created by the newer composition.
  Do not test rollback on a cluster without approval.

**Done:** rollout prerequisites, ownership boundaries, approval needs, and
rollback limits are stated in the handoff.
