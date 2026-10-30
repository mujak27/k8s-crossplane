# Public manifest validation

From the repository root, create an isolated Python environment, install pinned packages, then run the same command used on every pull request:

```sh
python3 -m venv .venv
. .venv/bin/activate
python -m pip install --require-hashes -r validation/requirements.txt
scripts/install-validation-tools.sh
export PATH="$HOME/.local/k8s-crossplane-validation/bin:$PATH"
scripts/validate.sh
```

The installer verifies SHA-256 checksums for Kustomize 5.6.0, kubeconform 0.6.7, gitleaks 8.24.2, and Crossplane CLI 2.5.0 for macOS/Linux amd64 and arm64. Python packages are version- and hash-locked to official PyPI artifacts in `validation/requirements.txt`. CI runs this exact validation command on every public `pull_request`, including documentation-only changes.

`validation/roots.txt` inventories every tracked local Kustomize root and explicitly selected remote public raw manifests. A local root prefixed with `empty ` is still built and must produce no resources; the existing `apps` registry and `crossplane/01-tls-ingress/compositions` scaffold are intentionally empty. Project 01's actual deployed definitions (`xrd.yaml`, `composition.yaml`, and `rbac.yaml`) are separately rendered via pinned full-SHA raw GitHub URLs; the root checker requires these URLs to align with the same repository and commit recorded for that XR. Remote entries are singleton Kustomize inputs, not recursive Argo source discovery. Argo remote/private sources and Helm output are never followed. Tracked Kustomization files and workflow/linter configuration YAML are lint-only; tracked API documents are separately passed to schema partitioning. The root list and `validation/xr-sources.tsv` are the only project-enrollment registries.

The strict kubeconform pass uses Kubernetes 1.36.0 schemas pinned at `f7d855e49c34b039c9ef2196444910275e31e09e` and CRDs-catalog commit `3eb90d47aba8d61919d4419dd38301536e32a94b`. Exact project XR GVKs are routed to Crossplane CLI validation against the upstream XRD at the same immutable source commit as each definitions pin. The registry verifies the deployed source field/ref and resolves release tags to their peeled commit. In particular, the annotated `tls-ingress-custom-v0.1.0` tag object is `deab38cbdbabf1f0441dce6567022ec07eeb5a03`, and its peeled commit is `a15c116d7d46515c6e149964cbf450ed56305671`; the deployed tag is unchanged. v2 XRDs must declare `spec.scope: Namespaced`; the CLI's missing-scope behavior is not accepted. The Crossplane `--crossplane-image=` flag is an undocumented, version-sensitive beta CLI behavior, verified here to avoid pulling an OCI image for XR-only validation.

The run needs network access to fetch pinned public remote Kustomize bases, schemas, and upstream XRDs; it is not an offline validator. Temporary render, schema cache, and fetched XRD data are removed on success or failure. Gitleaks scans a temporary copy of the current tracked working tree with findings redacted; it does not scan history. Schema validation does not establish API-server admission, Crossplane reconciliation, Function behavior, Helm chart output, readiness, or TLS correctness. Existing project 03 Ruby validators are unchanged.
