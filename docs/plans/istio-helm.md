# Istio Helm installation plan

Status: proposed; no installation manifests or cluster changes yet.

## Goal and scope

Install Istio base, control plane (`istiod`), and a dedicated ingress gateway
through Argo CD Helm Applications, matching the existing `infra/*` pattern.
Keep NGINX, cert-manager, Crossplane, and existing application traffic unchanged.
Do not enable mesh injection on existing workload namespaces in this change.

Assume a single-cluster, default-revision installation. Ambient mode (CNI and
ztunnel), egress gateways, application migration, and observability add-ons are
outside this scope. These three charts alone do not install an ambient mesh.

## Proposed releases

Repository: `https://blob.istio.io/istio-release/charts`.

| Argo CD Application / Helm release | Chart | Namespace | Proposed wave |
| --- | --- | --- | --- |
| `istio-base` | `base` | `istio-system` | `-30` |
| `istiod` | `istiod` | `istio-system` | `-20` |
| `istio-ingress` | `gateway` | `istio-ingress` | `-10` |

Pin all three charts to the same exact version. Candidate: **1.31.1**, the
current release advertised by the official documentation when this plan was
written (2026-10-02). Confirm chart availability and the target Kubernetes
version before implementation: Istio 1.31 supports Kubernetes 1.32–1.36.
If the cluster is outside this range, resolve compatibility before installing.

Use `project: default`, destination `https://kubernetes.default.svc`, explicit
`helm.releaseName`, and `helm.valuesObject`, consistent with existing apps.
Use `CreateNamespace=true`, `ServerSideApply=true`, `prune: false`, and no
cascading deletion finalizer. Enable automated self-healing only after the
initial staged rollout is complete.

Argo CD renders Helm templates; it does not create Helm-managed releases.
Use Argo CD and Kubernetes status for validation, not `helm ls`.

## Component settings

### Base

- Install Istio CRDs; do not set `skipCrds: true`.
- Set `defaultRevision: default` for the default validation webhook.
- Keep CRD deletion outside routine pruning or rollback.

### Control plane

- Deploy the default, unrevisioned `istiod` in `istio-system`.
- Set `base.validationFailurePolicy: Fail` in the **istiod chart** as documented
  for server-side apply of Helm-rendered manifests, avoiding validation webhook
  field ownership conflicts.
- Keep `istio-system` out of workload injection.
- Proposed homelab sizing: `replicaCount: 1` and
  `autoscaleEnabled: false`; confirm capacity against chart resource
  requests before implementation. This is not a highly available setup.
- Keep mesh behavior at chart defaults; no global strict mTLS or automatic
  workload enrollment in the installation change.

### Gateway

- Deploy a separately managed ingress gateway in `istio-ingress`.
- Do not label its namespace `istio-injection=disabled`: the gateway chart
  relies on Istiod's injection webhook to populate the proxy configuration.
- Proposed sizing: `replicaCount: 1`, `autoscaling.enabled: false`.
- Proposed exposure: `service.type: NodePort`,
  `service.externalTrafficPolicy: Cluster`, HTTP NodePort `30081`, HTTPS
  NodePort `30444`, and status NodePort `30021`. Check all three are free and
  in the cluster's configured NodePort range before applying.
- Override the full `service.ports` list, preserving the chart's status, HTTP,
  and HTTPS entries and target ports. Restrict status-port access to trusted
  monitoring/admin networks; it need not be exposed on the external router.
- If a working LoadBalancer implementation exists, consider LoadBalancer
  instead of NodePort before finalizing the values.
- Installing the gateway Deployment/Service does not configure listeners,
  routes, or TLS certificates. Those require a separate routing change.

## Planned file changes

Create `application.yaml` and `kustomization.yaml` in each of:

- `infra/istio-base/`
- `infra/istiod/`
- `infra/istio-ingress/`

Register all three directories in `infra/kustomization.yaml` after the rollout
strategy is agreed. Do not modify `bootstrap/root-app.yaml`'s `main` revision
just to test this branch. Add installation/validation notes to `README.md`.

## Rollout and readiness gates

1. Preflight: confirm Kubernetes version, available resources, port allocation,
   namespace labels, and whether any Istio installation already exists. Do not
   adopt or overwrite existing resources without an explicit migration plan.
2. Render all three pinned charts with the proposed values and target Kubernetes
   version; inspect CRDs, webhooks, Services, Deployments, and RBAC. Run
   `kubectl kustomize infra` to validate Application wiring.
3. Publish the Applications with child automated sync disabled initially. The
   root Application automatically creates children when changes reach `main`.
4. Sync `istio-base`; wait for its Application to be Synced and all installed
   Istio CRDs to be Established.
5. Sync `istiod`; wait for deployment availability, ready Service endpoints,
   and working injection and validation webhooks.
6. Sync `istio-ingress`; wait for deployment availability. Confirm its proxy
   image was injected correctly (not the chart's `auto` placeholder), its
   Service ports match the proposal, and `istioctl proxy-status` reports its
   configuration synchronized with Istiod.
7. Enable automated sync/self-healing after all three stages pass.

The proposed parent-level sync waves order Application resources, not
necessarily completed child installations. Do not rely on them alone for
readiness. Use the explicit gates above unless child Application health
assessment and cross-application orchestration are deliberately configured
and tested. Repeat readiness gates for upgrades.

## Acceptance and follow-up

- All three Applications report Synced/Healthy after deployment.
- Istio CRDs are Established; Istiod and gateway deployments are available.
- Gateway is connected to Istiod; `istioctl analyze --all-namespaces` has no
  unexplained installation errors.
- Existing NGINX traffic and other infrastructure remain functional.
- A separate, opt-in smoke-test change can add an Istio
  `networking.istio.io` Gateway, VirtualService, and disposable HTTP backend to
  verify actual traffic through NodePort `30081`.
- TLS follow-up should create a cert-manager Certificate/Secret in the gateway
  namespace and reference it from the listener configuration. Existing
  cert-manager installation alone does not provide gateway TLS.
- Kubernetes Gateway API is an alternative routing decision; its CRDs are not
  supplied by the Istio base chart. Avoid accidental duplicate gateway
  Deployments from auto-provisioning alongside this Helm-managed gateway.

## Upgrade and rollback safety

Upgrade base, then Istiod, then gateway, checking readiness at each stage and
keeping versions aligned. Data plane must not be newer than the control plane.
Restart/reconcile gateway pods when required to receive updated injected
configuration. Review supported upgrade paths before minor-version upgrades.

On failure, stop further syncs and preserve existing ingress traffic. Do not
blindly downgrade CRDs. Revert compatible configuration through Git and perform
an explicitly approved, staged recovery. Removing entries from the root with
`prune: false` does not uninstall children. Any deliberate uninstall must remove
gateway before control plane, with base/CRDs last; deleting CRDs destroys their
custom resources and requires separate approval.

## Decisions to confirm before implementation

1. Target Kubernetes version and whether Istio 1.31.1 is compatible.
2. NodePort versus LoadBalancer; approve/check proposed ports.
3. Single-replica homelab sizing versus HA/autoscaling.
4. Initial routing API and TLS/domain requirements (can remain a follow-up).

## References

- https://istio.io/latest/docs/setup/install/helm/
- https://istio.io/latest/docs/releases/supported-releases/
- https://istio.io/latest/docs/setup/additional-setup/gateway/
- https://github.com/istio/istio/blob/1.31.1/manifests/charts/gateway/values.yaml
