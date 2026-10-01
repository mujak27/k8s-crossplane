a minimal k8s argo for my new homelab,
intended to test crossplane functionality

## Crossplane

`infra/crossplane` installs Crossplane using the official stable Helm chart,
pinned to `2.4.2`. The root Argo CD application includes it through
`infra/kustomization.yaml` and creates the `crossplane-system` namespace.
Chart defaults are used; providers and composition functions are not installed.

After merging to `main` and syncing the root application, check the installation:

```sh
kubectl get application crossplane -n argocd
kubectl get pods -n crossplane-system
```
