# Isolated secure-egress demo

This is an in-cluster routing/TLS demo, not internet egress or a network-isolation
guarantee. The client application sends plain **HTTP on 80**; its sidecar sends
**ISTIO_MUTUAL to gateway 443**; the gateway originates verified **SIMPLE TLS to
origin 443**. The unmeshed nginx origin, not the client application, serves HTTPS.

## Ownership and interfaces

- `infra/secure-egress-namespaces` is the only declaration owner of `istio-egress`,
  `secure-egress-origin`, and `secure-egress-demo`. Demo sidecar injection is
  enabled there, not through a duplicate namespace in this project.
  Origin injection is disabled; gateway object injection remains eligible.
- `infra/istio-egress` declares the automated-sync gateway Helm Application.
  Service: **istio-egress.istio-egress.svc.cluster.local**. Exact Service and
  Deployment selector: **`app: istio-egress`, `istio: egress`**. Exposed ports are
  **443 → 443** (ISTIO_MUTUAL listener) and **15021 → 15021** (health), TCP.
  The profile uses **443**, the exposed Service port. The chart alone does not
  create a traffic listener: the XR supplies the Gateway.
- `origin/` contains only the origin Deployment, headless Service, ConfigMap and
  cert-manager Certificate. Its namespace is not duplicated here. The exact DNS
  identity/SAN/upstream SNI is
  **origin.origin-headless.secure-egress-origin.svc.cluster.local**.
  nginx listens directly on **443** because headless DNS bypasses targetPort
  translation. One replica and Recreate avoid overlapping stable pod hostnames;
  downtime during replacement is intentional.
- cert-manager generates `secure-egress-origin/origin-tls` via existing
  `ClusterIssuer/selfsigned-ca`; no Secret or key is declared in Git. nginx mounts
  the server key only in the origin. It does not automatically reload renewed
  certificates: an explicitly authorized origin restart is required after rotation.
- The registry contains only the parent `istio-secure-egress` Application. Its
  workload Kustomization owns only the ApplicationSet, which generates separate
  `origin`, `upstream`, `compositions`, `xr` and `client` Applications. RollingSync
  automatically syncs origin/upstream/compositions before XR, then client, with
  child `syncPolicy.automated` intentionally absent. It orders Argo health,
  **not** all operational prerequisites. No prune/finalizers or namespace
  creation options are added; shared Functions remain solely in `_shared`.
- `upstream/` owns the independent gateway-namespace DestinationRule, not the XR.
  Its ApplicationSet child is separate from origin and composed resources.
  The private repository owns `istio-egress/secure-egress-origin-ca`, an Opaque
  Secret containing only `ca.crt`. No public trust Secret or namespace duplicate
  is declared here. No pruning or deletion finalizers are introduced.
- `compositions/` imports only the released XRD and Composition at
  `istio-secure-egress-v0.1.0` (commit
  `c9b64ce3cad0c36461e380f5c4f67a1d79ed5aaf`), plus local profile and native RBAC.
  `EnvironmentConfig/istio-egress-secure-egress` is cluster-scoped routing data,
  not authorization. `xr/` enables the Namespaced composite API
  `platform.mujak.com/v1alpha1`, kind `XIstioSecureEgress`, name and namespace
  `secure-egress-demo`, with explicit Composition
  `istio-secure-egress.platform.mujak.com`. Its four native Istio resources share
  that name/namespace. The independent upstream rule is not one of those four.
- `client/` owns one **suspended** Job, not a hook. No client pod or traffic exists
  until an operator explicitly resumes it. Argo ignores only this Job's
  `/spec/suspend` and respects that difference during sync, preserving operator
  control. Kubernetes native sidecar injection lets the proxy terminate when curl
  exits. The client Application may report Suspended until resume; that is the
  intentional gate, not a reason to auto-unsuspend. Admission and completion
  behavior still require live verification.

Read-only RBAC inspection on 2026-10-22 found the existing
`crossplane:system:aggregate-to-crossplane` role already grants `*` on
`apiextensions.crossplane.io/*`, aggregated into `crossplane` and bound to
`crossplane-system/crossplane`. This covers EnvironmentConfig get/list/watch;
no duplicate grant is added. The new role grants only get/list/watch/create/
update/patch/delete on serviceentries, gateways, destinationrules and
virtualservices. It grants no Secret or status wildcard access. The installed
Function service account had no direct RoleBinding/ClusterRoleBinding; its
applicable group bindings were Kubernetes discovery/basic-user roles, not Secret
readers. This does not remove Crossplane's pre-existing controller Secret rights.
Recheck effective RBAC at rollout; never grant the Function Secret access.

## Upstream trust and manual rotation

The gateway selects `app: istio-egress`, `istio: egress` and originates SIMPLE
TLS on port 443, using `credentialName: secure-egress-origin-ca`. The SNI and
exact DNS SAN match the origin identity above; verification is explicitly enabled
and the rule is exported only to its namespace. This is distinct from the
client-to-gateway ISTIO_MUTUAL leg. It does not require client application TLS.

The CA-only Secret and its GitOps Application live under the private repository's
`infra/secure-egress-trust`; that repository records the freshly captured public
root fingerprint and validity. The source is only the public `tls.crt` field of
`cert-manager/selfsigned-root-ca`. Never export the full source Secret, its key,
or the origin server key; never put PEM in this public repository.

For CA rotation, obtain separate authorization for capture, deployment and any
restart. Revalidate the new public CA's CA:TRUE, dates, self-signature and SHA-256
fingerprint against the intended issuer. Review a private-only `ca.crt` bundle
update and reconcile it before serving a leaf signed by the new root. A staged
old/new public-root overlap is possible during manual rotation; remove the old
root after all consumers move. Recheck each certificate in the bundle. Confirm
gateway SDS adopted the bundle; do not assume Git sync proves adoption. Have
cert-manager renew the origin leaf through its existing issuer workflow and
explicitly restart nginx to reload it. Verify the exact SAN/SNI and successful
gateway handshake before removing old trust. No rotation controller is added.

Missing/untrusted CA, expired certificates or a SAN mismatch must fail upstream
TLS (typically surfaced as a gateway 503), never fall back to plaintext or skip
verification. SDS inspection, successful traffic and controlled negative tests
remain separately authorized live checks; local renders prove none of them.

## Published pins (registry evidence, 2026-10-22)

Docker Registry v2 manifest GETs for the exact tags returned the following
`Docker-Content-Digest` values, also verified by SHA-256 of the response bodies:

| Artifact | Immutable identifier |
| --- | --- |
| `docker.io/curlimages/curl:8.12.1` index | `sha256:94e9e444bcba979c2ea12e27ae39bee4cd10bc7041a472c4727a558e213744e6` |
| curl linux/arm64/v8 manifest in that index | `sha256:62dc7f48483d54c86914bf0aed8031bb07ac70eb4ef423b97e6af6592df163b5` |
| curl linux/amd64 manifest in that index | `sha256:88a9abad9d958340e48564f9bdcdaa29916a2984be59314da709f8bbc0eef6f7` |
| `docker.io/library/nginx:1.28.3-alpine` index | `sha256:a8b39bd9cf0f83869a2162827a0caf6137ddf759d50a171451b335cecc87d236` |
| nginx linux/arm64/v8 manifest in that index | `sha256:1be286f7dd7d6e6be04f46e8df36d0084b05aa3d7fd3c6ebda3e1eff4e5b665d` |
| `docker.io/istio/proxyv2:1.31.1` index | `sha256:d86cba0dd1eb15c00b6901c69ce5ae3d2d5f8427a47751098cf8c3ab2a4a62e9` |
| proxyv2 linux/arm64 manifest in that index | `sha256:41c291555b4bbed797cfdeea872784047d448f4d72373af4542d2af6a03beeef` |
| Istio `gateway` chart 1.31.1 archive | `sha256:bfeb6ecf73586e6992c038daae518d11795e932a7c2d034f6e16c7e60638757e` |

All three image indexes include linux/amd64 and linux/arm64. The chart checksum agrees with its
published [index](https://blob.istio.io/istio-release/charts/index.yaml).
Argo's Helm source pins the chart version; it does not enforce the recorded
archive digest. Local validation verifies the archive before rendering.
The chart intentionally renders `image: auto`: Istio's
[1.31.1 gateway injection template](https://github.com/istio/istio/blob/1.31.1/manifests/charts/istio-control/istio-discovery/files/gateway-injection-template.yaml)
honors the digest-pinned `sidecar.istio.io/proxyImage` annotation at admission.
Actual injected image selection must still be checked live.

## Local validation and rollout boundary

From the repository root (Ruby standard library, kubectl, Helm and curl only):

```sh
ruby crossplane/03-istio-secure-egress/validate-platform.rb
ruby crossplane/03-istio-secure-egress/validate-trust.rb
ruby crossplane/03-istio-secure-egress/validate.rb
# Optional: Docker + Crossplane CLI; runs the released binary, no cluster writes.
ruby crossplane/03-istio-secure-egress/validate.rb --render
git diff --check
```

The platform script downloads only the pinned chart into a temporary directory, verifies
its digest, renders the actual values, and asserts namespace, selector, port,
injection, image, headless DNS and certificate contracts. It compares existing
ingress declarations and Helm rendering with fixed prerequisite `d05bc6b`.
`infra` is the root Application's entrypoint; no repository-root Kustomization
exists. Local renders establish declarations, not cluster availability.

The agreed automated seam is **rendered resource/ownership contracts**, using
Ruby standard-library assertions, not a new test framework. Actual traffic/TLS
is a separate live seam. `validate.rb` compares tag-rendered definitions with the
approved release commit, renders every child and existing project, and checks
exclusive ownership, scope, RBAC, profile, HTTP client and suspended gate.
`--render` additionally executes the exact released package **by digest** with
the Crossplane **v2.4.2 Docker render engine**, supplying the real local
EnvironmentConfig through `--required-resources`. It asserts the actual four
native outputs, routes, exports, selector, listener and mTLS subset. No upstream
fixture or Development annotation is used; no source build or upgrade occurs.

Observed locally on 2026-10-22: all three public validators and `--render` passed;
the private trust validator at private commit `9d431c7` passed with values
suppressed. Registry manifest responses for curl's exact tag and both platform
manifests matched their returned digests by independent SHA-256 calculation.
The local CLI was v2.5.0; the explicitly selected render engine was v2.4.2.
The initial mock observation correctly reported XR Ready=False: no live composed
objects were supplied. Generated output is not proof of Kubernetes admission,
target-cluster required-resources handling, XR reconciliation, injection, SDS,
DNS, TLS or traffic. Exact-package target startup evidence and its limitations
remain in `crossplane/README.md`. No live mutation was performed for #19.

## Operator rollout — separate explicit authorization required

The following is a runbook, **not permission to execute it**. Push/merge, Argo
syncs, resume, test mutations, restarts and cleanup each require authorization.
Use context `orbstack` only after reconfirming its API server and intended target.
Keep the Job suspended throughout preparation. Argo waves order Application
creation, not runtime readiness; RollingSync is not an automatic security gate.
Newly automated standalone Istio and private trust apps
retry failed syncs indefinitely with exponential backoff from 5s capped at 3m.
They may race namespaces, XRDs, webhooks and Functions; retry is not readiness or
security acceptance. Observe admission failures and recover prerequisites rather
than assuming automated reconciliation succeeded. This policy does not authorize
live commands or client resume; all TLS/security gates below still apply.

1. Before relying on dependent XRs, recheck the exact shared package digest and
   Function Installed/Healthy plus active revision/runtime health. Existing
   startup success used a cached image; fresh registry pull/auth remains untested.
   Fail closed on runtime errors. Do not rebuild, substitute a package, configure
   emulation or upgrade Crossplane. Confirm Istio 1.31.1 CRDs, istiod/webhook and
   cert-manager/`ClusterIssuer/selfsigned-ca` readiness.
2. With deployment authorization, sync the infra namespace declarations (demo
   injection enabled, origin disabled, gateway injection not disabled). Observe
   automated reconciliation of `istio-egress`, private `secure-egress-trust` and
   the public parent. RollingSync automatically syncs origin/upstream/compositions
   before XR, then the suspended client; the XR is enabled, not a commented example.
   Verify Progressive Syncs is enabled and generated Applications have the intended
   paths, no child automated policy, no pruning and no cascading finalizers.
   Stop rollout acceptance on unhealthy dependencies; recover failed admission
   and keep the client suspended rather than bypassing a gate.
3. Check XRD/CRD establishment, actual profile contents and effective controller
   RBAC (four native kinds plus existing EnvironmentConfig get/list/watch).
   Reinspect controller RoleBinding/ClusterRoleBinding aggregation and Function
   bindings; no Function Secret permission is needed. Check origin Certificate
   Ready, matching exact DNS SAN/issuer/dates, origin Deployment Ready, headless
   endpoint and DNS resolving the exact hostname to the origin pod IP. Confirm
   nginx actually serves TLS on 443 with a CA-verified handshake, explicit
   `-servername`/`-verify_hostname` and `-verify_return_error` using the approved
   public CA, never `-k`/skip-verify. Any temporary probe needs its own approval.
4. After XR sync, require Synced=True and Ready=True, and inspect
   `spec.crossplane.resourceRefs`: exactly ServiceEntry, Gateway, DestinationRule
   and VirtualService, all `networking.istio.io/v1`, same XR name/namespace and
   owner UID. Ready reflects configuration matching, **not path health**.
   Independently confirm no competing host/listener or generated-resource owner.
5. Verify the actual gateway pod is Available/Ready, its injected image matches
   the pinned proxy digest, Service selectors/endpoints match the profile and
   port 443 is exposed. Cross-namespace Gateway selection must work:
   `PILOT_SCOPE_GATEWAY_TO_NAMESPACE` was unset (Istio default false); recheck
   effective behavior without changing mesh-global settings. Inspect discovery
   selectors, Sidecar imports/exports and any policy overrides for visibility.
   ServiceEntry/VirtualService export to demo and gateway namespaces; the
   gateway-host DestinationRule exports locally to the demo, upstream rule
   locally to the gateway. Reject unintended listener conflicts or decorators.
6. Inspect only the private trust Secret's **key names/type**, never values in a
   transcript: Opaque, exactly `ca.crt`. Confirm gateway SDS actually loaded that
   trust and its identity/validity matches the approved root. Confirm listener
   443 uses ISTIO_MUTUAL, the declared source route selects the gateway subset with mTLS,
   and the gateway outbound origin cluster uses SIMPLE, the expected CA/SNI/SAN,
   verification enabled and port 443. Example read-only inspection commands
   (`$GATEWAY_POD` is selected from the actual gateway Deployment):

   ```sh
   istioctl --context orbstack analyze -A
   istioctl --context orbstack proxy-status
   istioctl --context orbstack proxy-config listeners "$GATEWAY_POD" -n istio-egress
   istioctl --context orbstack proxy-config routes "$GATEWAY_POD" -n istio-egress
   istioctl --context orbstack proxy-config clusters "$GATEWAY_POD" -n istio-egress
   istioctl --context orbstack proxy-config secrets "$GATEWAY_POD" -n istio-egress
   ```

   The secrets summary is sufficient; do not dump private keys/PEM or commit
   proxy secret dumps. Resolve all relevant analyzer errors and stale proxies.
   Save baseline gateway counters before traffic (for example,
   `pilot-agent request GET stats` in its `istio-proxy` container); identify the
   exact outbound origin cluster's request/connection/TLS counters. Do not enable
   broad access/debug logging. Narrow additional logs need separate agreement.

### First traffic and evidence

Only after all gates above and explicit first-traffic approval, resume the
existing Job; do not change the Git declaration to auto-run:

```sh
kubectl --context orbstack -n secure-egress-demo patch job secure-egress-client --type=merge -p '{"spec":{"suspend":false}}'
kubectl --context orbstack -n secure-egress-demo get pods -l job-name=secure-egress-client -o wide
kubectl --context orbstack -n secure-egress-demo logs job/secure-egress-client -c client
kubectl --context orbstack -n secure-egress-demo wait --for=condition=complete job/secure-egress-client --timeout=120s
```

Confirm admission injected a running native `istio-proxy` init sidecar before
curl starts, capture was not excluded, and actual client imageID matches the
published ARM64 manifest. The single bounded curl request is plain HTTP port 80,
not HTTPS and not a direct request to the gateway IP. Expect the exact static
body `secure-egress origin reached` (newline, from `origin/configmap.yaml`) and
zero client exit status. Inspect client
routes/clusters if the short-lived proxy is still running; if a retained proxy
is needed for diagnosis, obtain separate approval for that diagnostic change,
not an automatic extra request. Compare gateway origin-cluster counters
before/after for the request/connection and successful TLS handshake. Preserve
time-correlated proxy telemetry that independently proves the gateway leg. A
successful response or XR Ready **alone is not acceptance**. This proves an
isolated in-cluster path, not internet egress or prevention of bypass.

### Controlled negative cases — additional mutation approval required

Do not execute these as part of local validation. Approve an isolated test window,
exact patches, an unrelated public test CA, reruns and restoration first. Suspend
the client and record the approved upstream rule before each case. Change only
the independently owned `istio-egress/secure-egress-origin-tls` DestinationRule;
coordinate its generated upstream Application's sync so it does not overwrite
the deliberate temporary difference. Never alter the shared issuer or source CA.

- **SAN mismatch:** change only upstream `subjectAltNames` to an incorrect DNS
  name while retaining the correct SNI and CA, isolating certificate-name
  validation. Confirm the effective gateway cluster adopted that change.
- **Untrusted CA:** restore the SAN, provision a temporary CA-only Secret in
  `istio-egress` containing an approved unrelated public CA (no keys), and change
  only `credentialName` to that Secret. Confirm SDS loaded it, rather than merely
  testing a missing credential. Keep SNI/SAN and verification enabled.

For each, with approval delete/recreate only the completed client Job via its
Application (it returns suspended), then explicitly resume for one request. The
client must fail (typically gateway HTTP 503, hence nonzero curl exit) and
gateway telemetry must identify certificate verification failure, not unrelated
DNS/readiness errors. Never use insecure curl or skip verification. After each
case restore the approved rule through upstream sync and approved CA credential,
confirm effective proxy restoration, and rerun the positive case. Remove the
temporary test Secret only after checking consumers. Preserve evidence of both
failures and final successful restoration; failures alone are not acceptance.

## Retirement — document only, do not execute without approval

Stop/suspend client traffic first. Remove its Job declaration, sync without
pruning, and explicitly delete its Job/pods with authorization. Remove the XR
declaration, sync without pruning, then explicitly delete the live XR and verify
its four owned native resources are cleaned up. Check for other consumers before
retiring origin, upstream rule, gateway/profile and private trust, in that order.
To stop project reconciliation, remove its registry entry, explicitly delete the
parent Application **without cascading**, then delete its remaining ApplicationSet
with orphan propagation and its child Applications without cascading. Otherwise
the still-live parent/ApplicationSet can recreate children. Remove the gateway
and private trust registrations and explicitly retire those Applications without
cascading too, before their workload cleanup. Perform each approved resource
deletion explicitly; removing files does not delete live resources. Do not retire
the shared Function, issuer or unrelated projects. Namespace deletion is not a
substitute for ownership-aware cleanup.
With pruning disabled, removing Git entries does **not** delete Applications or
workloads; remaining Applications can still reconcile them. Check finalizers and
remaining resources rather than assuming cleanup. This short-lived demo adds no
HA, automatic certificate reload/trust rotation or zero-downtime promise.
