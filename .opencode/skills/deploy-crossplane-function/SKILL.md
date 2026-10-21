---
name: deploy-crossplane-function
description: Deploy a custom Crossplane function into this GitOps repository from published packages and pinned upstream definitions. Use when adding or deploying a new custom function project, its shared Function, RBAC, XR, or Argo CD wiring.
---

# Deploy a Crossplane function

Read `crossplane/README.md` first. It is the source of truth for registry,
version, ownership, and standard render conventions; this skill adds deployment
decisions and completion criteria on top.

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
- Upstream path: record the exact published directory path, including its
  numeric prefix (`02-tls-ingress-custom`). Remote resource URLs use that path.
- Local project ID: remove the ordinal prefix only where local naming uses a
  project ID (`02-tls-ingress-custom` becomes `tls-ingress-custom`).
- Definitions ref: pin per the version convention in `crossplane/README.md`.
  Read the pinned base's `kustomization.yaml`; it must select only the XRD and
  Composition, not Functions, example XRs, render scripts, or RBAC.
- Function package: a published image and explicit version, never `latest`.
- Resolved evidence: the definitions ref's commit and the package digest where
  available. Tags are immutable by convention, not guaranteed; release metadata
  alone does not prove OCI publication or architecture.
- Required inputs: package architecture, Crossplane version, required providers
  or controllers, and function-specific configuration such as an
  EnvironmentConfig, issuer, or gateway only when the actual function requires
  it.
- Compatibility: package and definitions releases may differ. Read the pinned
  XRD/Composition and the package release notes to confirm the fields and
  behavior the Composition expects; record it as verified or unverified.

If the package, pin, or definitions-only base is missing, stop and report the
exact missing artifact. Do not invent a pin, import individual upstream files
from `main` as legacy `01-tls-ingress` does, or begin upstream authoring. If
publication, architecture, or compatibility cannot be verified, report it as
unverified.

**Done:** contract recorded with exact refs, resolved evidence, required inputs,
and compatibility status, or a precise blocker report. Missing artifacts block
wiring; any unverified publication, architecture, or compatibility blocks
rollout.

## 2. Check identities and contracts

- XRD identity is `<plural>.<group>`; kind, plural, group, and served version
  must match the pinned Composition and XR.
- Take the Composition name from the pinned upstream artifact. Verify it is
  unique cluster-wide and selected by the XR; a conflict blocks the work. Do
  not rename an upstream Composition here.
- XR schema, required fields, health enums, and scope come from the pinned XRD.
  In the Crossplane v2 contract, select the Composition with
  `spec.crossplane.compositionRef`.
- Use the actual scope: do not assume XRs or composed resources are namespaced.
  XRDs, Compositions, Functions, and aggregate ClusterRoles are cluster-scoped.
- Check collisions by the actual names the XR and function produce. Same-kind
  namespace/name collisions cover XRs and composed resources; functions may
  also derive shared names across kinds, such as composed resources named after
  the XR. Check hostnames and Secrets separately. A new kind does not isolate
  them.
- List the composed kinds the pinned Composition and function documentation
  actually render; a pipeline-only Composition can hide them inside the
  function. Do not assume every function composes Ingress or Certificate
  resources.
- Readiness is function-specific: derive it from the composition logic and
  external resources. Some functions implement no readiness detector. Do not
  add auto-ready unless the contract needs it.

**Done:** every identity, selected Composition, required field, scope, collision,
composed kind, and readiness condition is traced to the pinned artifacts.

## 3. Wire a custom project

Create `crossplane/<NN>-<project-id>/` following the
`crossplane/02-tls-ingress-custom/` example:

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

- Follow `crossplane/README.md` for registry and ownership rules. Add only
  `<NN>-<project-id>/application.yaml` to `crossplane/kustomization.yaml`;
  never project or workload directories, and never `_shared/`.
- Keep the single `infra` reference to the registry; the parent must not manage
  itself.
- Leave `01-tls-ingress` and `02-tls-ingress-custom` byte-for-byte unchanged.

**Done:** every required path exists with the intended ownership, and the
registry adds exactly one Application reference.

## 4. Validate locally

Run the standard renders in `crossplane/README.md`, then the new project's own:

```sh
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
- Upstream definitions: the pinned ref appears in
  `compositions/kustomization.yaml`; the resolved base selects only the XRD and
  Composition. The local compositions render contains those definitions plus
  the intended local aggregate ClusterRole.
- XR: kind, version, and scope match the pinned XRD; a namespaced XR uses the
  intended namespace; `compositionRef` names the pinned Composition; required
  fields are present.
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
- Only after explicit live-sync approval, sync `crossplane-shared` and verify
  the Function package is Installed and Healthy before syncing XRs. Confirm the
  XRD is Established and the Composition is selected. Check only the
  prerequisites the function actually requires, such as an issuer, ingress,
  gateway, backend service, or EnvironmentConfig.
- Rollout stays blocked until every required prerequisite and compatibility
  claim is verified; preparatory wiring may continue, but do not report the
  deployment as ready.
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
- Rollback restores the previous pinned Function and definitions. It does not
  guarantee removal of resources created by the newer composition. Do not test
  rollback on a cluster without approval.

**Done:** rollout prerequisites, ownership boundaries, approval needs, and
rollback limits are stated in the handoff.
