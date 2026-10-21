# k8s-crossplane

GitOps repository for a homelab Kubernetes cluster, with Crossplane projects
managed as Argo CD Applications.

## Language

**Project ID**:
The stable identifier of a Crossplane compilation project.
_Avoid_: project number, app name

**Definitions Base**:
An upstream Kustomize base that supplies a project's XRD and Composition.
_Avoid_: composition bundle, manifest folder

**Function Package**:
A versioned OCI package that provides a Crossplane composition function.
_Avoid_: function image, addon

**Parent Application**:
The Argo CD Application for a project's own ApplicationSet and generated
Applications.
_Avoid_: root app, project app
