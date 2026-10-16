# Metrics Server

Provides live container CPU/memory usage through `metrics.k8s.io/v1beta1` for
`kubectl top` and the CustomDeployment learning controller. kube-state-metrics
in `monitoring` reports Kubernetes object state; it does not provide this API.

The root Argo CD Application discovers this Application through `infra/`.
Chart **3.14.0** pins Metrics Server **0.9.0**, which supports Kubernetes **1.34+**.
The chart's single-replica defaults suit the existing one-node test cluster.

## TLS and ownership

- Existing cert-manager issues the Metrics Server serving certificate. Its CA
  injector supplies the APIService trust bundle; Argo CD ignores only that field.
- Metrics Server verifies kubelet certificates against the mounted cluster CA.
  No `--kubelet-insecure-tls` override is configured. If the kubelet has a different
  issuer or missing address SANs, diagnose its certificate rather than disabling
  verification.
- Argo CD manages this shared prerequisite. Do not use `helm install` or direct
  `kubectl apply` to install it. Merging to `main` permits automated reconciliation,
  including cluster-scoped APIService and RBAC resources. Automated pruning is off.

## Observed baseline — 2026-10-16

Read-only checks used explicit context `orbstack`. The control-plane endpoint was
`https://127.0.0.1:26443`; the only node, `orbstack`, was Ready on Kubernetes
`v1.36.5+orb1`. The live root Application tracked this repository's `main`, path
`infra`, at `8c46203e19aed74953c496560e4b4b8029a934bd` and was Synced/Healthy.

`kubectl --context orbstack get apiservice v1beta1.metrics.k8s.io -o yaml`
returned NotFound. No Metrics Server Deployment existed. kube-state-metrics was
Synced/Healthy and its Deployment was Ready; it remains unchanged.

**Pending:** merge, Argo CD reconciliation, kubelet TLS/connectivity checks from
Metrics Server, and an actual Ready-Pod metrics sample. Rendering is not evidence
of live metrics availability. The host-to-node TLS probe produced no certificate
and cannot establish in-cluster reachability or trust.

## Validate locally

From the repository root, with host-side Helm and kubectl installed (no cluster
writes; Helm may download the pinned chart into its local cache):

```sh
kubectl kustomize infra
ruby -ryaml -e 'puts YAML.load_file("infra/metrics-server/application.yaml").dig("spec", "source", "helm", "valuesObject").to_yaml' | helm template metrics-server metrics-server --repo https://kubernetes-sigs.github.io/metrics-server/ --version 3.14.0 --namespace kube-system --kube-version 1.36.5 --api-versions cert-manager.io/v1 -f -
git diff --check
```

Both renders passed on 2026-10-16 using Helm 4.3.1 and kubectl's Kustomize 5.8.1.
Assertions against the 11 chart resources passed for names, namespace, pinned
image, replica count, kubelet CA argument, APIService verification/CA injection,
certificate SAN/issuer, and the single registry entry. A first render used Helm's
default release name; the explicit release/chart arguments above corrected it.

## Verify after merge

Run from the repository root. These commands are read-only and explicitly select
the existing test cluster; recheck its identity before any future writes.

```sh
kubectl --context orbstack cluster-info
kubectl --context orbstack get nodes -o wide
kubectl --context orbstack -n argocd get application root metrics-server
kubectl --context orbstack -n kube-system rollout status deployment/metrics-server --timeout=120s
kubectl --context orbstack -n kube-system get certificate metrics-server
kubectl --context orbstack get apiservice v1beta1.metrics.k8s.io -o yaml
kubectl --context orbstack -n default get pods -o wide
kubectl --context orbstack -n default top pods --containers
kubectl --context orbstack get --raw /apis/metrics.k8s.io/v1beta1/namespaces/default/pods
```

Require the Argo CD Application to be Synced/Healthy, the certificate Ready, the
APIService Available, and a metrics entry matching a Ready Pod's name/container.
Use an existing Ready Pod; do not create or modify an unrelated workload for this
check.

In the raw response, CPU is average core usage over `window` ending at `timestamp`:
`100000000n` is 0.1 core (100m). Memory is working-set usage: `131072Ki` is 128Mi.
Neither is a utilization percentage; that requires dividing by matching resource
requests. Check the actual timestamp/window rather than assuming samples are fresh.

For failures, inspect without restarting or disrupting shared workloads:

```sh
kubectl --context orbstack -n kube-system logs deployment/metrics-server --tail=100
kubectl --context orbstack -n kube-system describe deployment metrics-server
kubectl --context orbstack -n kube-system describe certificate metrics-server
kubectl --context orbstack describe apiservice v1beta1.metrics.k8s.io
```

Distinguish certificate issuer/SAN errors from connectivity timeouts and kubelet
authorization failures. Record the actual results in
[CustomDeployment issue #1](https://github.com/mujak27/k8s-custom-controller-deployment/issues/1)
before marking that ticket complete. Do not disable Metrics Server for failure tests.

Sources: [pinned release compatibility](https://github.com/kubernetes-sigs/metrics-server/blob/v0.9.0/README.md),
[pinned chart values](https://github.com/kubernetes-sigs/metrics-server/blob/metrics-server-helm-chart-3.14.0/charts/metrics-server/values.yaml).
