a minimal k8s argo for my new homelab,
intended to test crossplane functionality

## Homelab certificate authority

`infra/homelab-pki` installs a self-signed root CA through cert-manager:

- `selfsigned-bootstrap` signs the root certificate.
- `Certificate/homelab-root-ca` generates an ECDSA P-256 root with a 10-year
  lifetime in the `cert-manager` namespace.
- `ClusterIssuer/homelab-ca` issues service certificates using that root.

The certificate and private key are generated in `Secret/homelab-root-ca`, not
stored in Git. The CA issuer uses cert-manager's default cluster resource
namespace (`cert-manager`); keep these aligned if that setting changes.
This is an online root suitable for a homelab, not an offline-root PKI.

Argo CD installs the cert-manager Application first, then the PKI Application.
Child Application waves alone do not guarantee CRD/webhook readiness. The PKI
Application retries failed syncs indefinitely with capped backoff, so it can
recover when cert-manager becomes ready. Persistent errors still need investigation.
Neither Application has cascading deletion enabled or automatic pruning enabled.

### Validate issuance

After syncing both applications, check readiness:

```sh
kubectl wait --for=condition=Ready clusterissuer/selfsigned-bootstrap --timeout=120s
kubectl -n cert-manager wait --for=condition=Ready certificate/homelab-root-ca --timeout=120s
kubectl wait --for=condition=Ready clusterissuer/homelab-ca --timeout=120s
```

Create a disposable test namespace and certificate (do not reuse a namespace
containing other workloads):

```sh
kubectl create namespace homelab-pki-test
kubectl apply -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: test
  namespace: homelab-pki-test
spec:
  secretName: test-tls
  duration: 2160h
  renewBefore: 360h
  dnsNames:
    - test.home.arpa
  issuerRef:
    name: homelab-ca
    kind: ClusterIssuer
    group: cert-manager.io
EOF
kubectl -n homelab-pki-test wait --for=condition=Ready certificate/test --timeout=120s
kubectl -n cert-manager get secret homelab-root-ca -o jsonpath='{.data.tls\.crt}' | base64 -d > homelab-root-ca.crt
kubectl -n homelab-pki-test get secret test-tls -o jsonpath='{.data.tls\.crt}' | base64 -d > homelab-test.crt
openssl verify -CAfile homelab-root-ca.crt homelab-test.crt
kubectl delete namespace homelab-pki-test
```

Use `homelab-ca` as the `issuerRef` for service Certificates in any namespace.
Set their duration explicitly to `2160h` (90 days); this is a convention, not a
limit enforced by the issuer. For Ingress resources, use the annotation
`cert-manager.io/cluster-issuer: homelab-ca`.

### Trust, backup, and rotation

Install the exported **public** `homelab-root-ca.crt` in the trust stores of
devices/browsers that should trust homelab services. Issuing a certificate does
not automatically distribute trust. In-cluster trust distribution is not included.

Securely back up the entire `homelab-root-ca` Secret, including `tls.key`, using
encrypted storage. Do not commit the Secret or its private key to Git. Kubernetes
Secrets are base64-encoded, not inherently encrypted: restrict access with RBAC
and enable Kubernetes encryption at rest. Losing the key without a backup means
replacing the CA and redistributing trust. Restore the Secret before syncing the
root Certificate into a rebuilt cluster to avoid generating a different root.

The root renews 90 days before expiry and retains its key. Renewal does not
redistribute its public certificate or automatically reissue existing service
certificates. Monitor root expiry and plan renewal/rotation ahead of time;
cert-manager's CA issuer does not ensure a service certificate expires before
its CA. For deliberate key rotation, introduce a new CA/Secret, distribute the
new public root alongside the old one, switch issuance, explicitly renew service
certificates, and remove old trust only after old certificates are retired.
Do not delete the existing root Secret as a rotation mechanism.
