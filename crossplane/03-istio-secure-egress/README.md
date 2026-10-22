# Isolated secure-egress demo — platform prerequisites

This is an in-cluster routing/TLS demo, not internet egress or a network-isolation
guarantee. The future client sends plain HTTP; the unmeshed origin serves HTTPS.

## Ownership and interfaces

- `infra/secure-egress-namespaces` is the only declaration owner of `istio-egress`,
  `secure-egress-origin`, and `secure-egress-demo`. The enabling ticket must add
  demo namespace injection there, not redeclare the namespace in this project.
  Origin injection is disabled; gateway object injection remains eligible.
- `infra/istio-egress` declares the manual-sync gateway Helm Application.
  Service: **istio-egress.istio-egress.svc.cluster.local**. Exact Service and
  Deployment selector: **`app: istio-egress`, `istio: egress`**. Exposed ports are
  **443 → 443** (future ISTIO_MUTUAL listener) and **15021 → 15021** (health), TCP.
  Use **443**, the exposed Service port, in the later gateway profile. The chart
  alone does not create a traffic listener: the later XR supplies the Gateway.
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
- The later #19 parent/ApplicationSet must add an origin child Application for
  `crossplane/03-istio-secure-egress/origin`. This slice deliberately leaves that
  workload entrypoint unregistered until then. Do not put workloads into the
  Crossplane registry: it continues to contain Applications only.
- `upstream/` owns the independent gateway-namespace DestinationRule, not the XR.
  #19 must register this workload entrypoint through the project ApplicationSet,
  separately from the origin and before XR traffic. Do not add it to the registry.
  The private repository owns `istio-egress/secure-egress-origin-ca`, an Opaque
  Secret containing only `ca.crt`. No public trust Secret or namespace duplicate
  is declared here. No pruning or deletion finalizers are introduced.

## Upstream trust and manual rotation

The gateway selects `app: istio-egress`, `istio: egress` and originates SIMPLE
TLS on port 443, using `credentialName: secure-egress-origin-ca`. The SNI and
exact DNS SAN match the origin identity above; verification is explicitly enabled
and the rule is exported only to its namespace. This is distinct from the later
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
| `docker.io/library/nginx:1.28.3-alpine` index | `sha256:a8b39bd9cf0f83869a2162827a0caf6137ddf759d50a171451b335cecc87d236` |
| nginx linux/arm64/v8 manifest in that index | `sha256:1be286f7dd7d6e6be04f46e8df36d0084b05aa3d7fd3c6ebda3e1eff4e5b665d` |
| `docker.io/istio/proxyv2:1.31.1` index | `sha256:d86cba0dd1eb15c00b6901c69ce5ae3d2d5f8427a47751098cf8c3ab2a4a62e9` |
| proxyv2 linux/arm64 manifest in that index | `sha256:41c291555b4bbed797cfdeea872784047d448f4d72373af4542d2af6a03beeef` |
| Istio `gateway` chart 1.31.1 archive | `sha256:bfeb6ecf73586e6992c038daae518d11795e932a7c2d034f6e16c7e60638757e` |

Both image indexes also include linux/amd64. The chart checksum agrees with its
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
git diff --check
```

The script downloads only the pinned chart into a temporary directory, verifies
its digest, renders the actual values, and asserts namespace, selector, port,
injection, image, headless DNS and certificate contracts. It compares existing
ingress declarations and Helm rendering with fixed prerequisite `d05bc6b`.
`infra` is the root Application's entrypoint; no repository-root Kustomization
exists. Local renders establish declarations, not cluster availability.

No live deployment or cluster mutation was performed for this slice. Separately
authorized checks must establish istiod/webhook readiness and actual gateway
injection/image, gateway availability/endpoints/listener, issuer and Certificate
Ready, origin pod Ready, exact DNS-to-pod-IP resolution, and a CA-verified TLS
handshake with the exact SAN/SNI (never insecure verification). A TCP readiness
probe alone is not TLS verification. Gateway listener readiness additionally
depends on the later XR. Trust/SDS and full gateway traversal remain later gates.
Exact Function startup health is not required-resources or XR reconciliation
proof; retain the runtime limitations documented in `crossplane/README.md`.
