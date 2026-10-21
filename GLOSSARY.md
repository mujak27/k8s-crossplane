# k8s-crossplane

GitOps repository for a homelab Kubernetes cluster, with Crossplane projects
managed as Argo CD Applications.

## Language

**Project ID**:
The stable name of a Crossplane compilation project, formed by dropping the
numeric ordering prefix from its upstream directory. Application, RBAC, XR, and
composed resource names derive from it.
_Avoid_: project number, app name

**Definitions base**:
An upstream Kustomize base containing only a project's XRD and Composition, at
an immutable release ref.
_Avoid_: composition bundle, manifest folder

**Function package**:
A published Crossplane Function image installed through a shared `Function`
declaration. Its release is independent of the definitions release.
_Avoid_: function image, addon

**Parent Application**:
The Argo CD Application that selects a project's workload Kustomization and owns
that project's ApplicationSet and generated Applications.
_Avoid_: root app, project app
