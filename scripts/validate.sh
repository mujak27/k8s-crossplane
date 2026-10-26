#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
for tool in python3 yamllint kustomize kubeconform crossplane gitleaks curl git tar; do
  command -v "$tool" >/dev/null 2>&1 || { echo "[tools] missing $tool; run scripts/install-validation-tools.sh" >&2; exit 1; }
done
tmp=$(mktemp -d "${TMPDIR:-/tmp}/manifest-validation.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

python3 -c 'import yaml' >/dev/null 2>&1 || { echo '[tools] PyYAML missing; run scripts/install-validation-tools.sh' >&2; exit 1; }
test "$(python3 -c 'import yaml; print(yaml.__version__)')" = '6.0.2' || { echo '[tools] expected PyYAML 6.0.2' >&2; exit 1; }
test "$(python3 -c 'import pathspec; print(pathspec.__version__)')" = '1.1.1' || { echo '[tools] expected pathspec 1.1.1' >&2; exit 1; }
test "$(yamllint --version)" = 'yamllint 1.35.1' || { echo '[tools] expected yamllint 1.35.1' >&2; exit 1; }
test "$(kustomize version --short 2>/dev/null | sed -n 's/^{v\([^ ]*\).*/\1/p')" = '5.6.0' || { echo '[tools] expected Kustomize 5.6.0' >&2; exit 1; }
test "$(kubeconform -v | sed 's/^v//')" = '0.6.7' || { echo '[tools] expected kubeconform 0.6.7' >&2; exit 1; }
test "$(crossplane version --client | awk 'NR==1 {print $NF}')" = 'v2.5.0' || { echo '[tools] expected Crossplane CLI v2.5.0' >&2; exit 1; }
test "$(gitleaks version)" = '8.24.2' || { echo '[tools] expected gitleaks 8.24.2' >&2; exit 1; }

echo '[yaml] lint tracked YAML'
git ls-files -z '*.yaml' '*.yml' | xargs -0 -r yamllint -c .yamllint.yaml

echo '[pins] verify upstream source references before any remote render'
while IFS='|' read -r apiversion kind source pin xrd witness ref repo; do
  case "$apiversion" in ''|'#'*) continue ;; esac
  python3 scripts/check-pin-witness.py "$witness" "$repo" "$ref" "$xrd" || { echo "[pins] local pin drift for $source ($ref/$xrd not in deployed source at $witness)" >&2; exit 1; }
  case "$ref" in
    *-v[0-9]*)
      resolved=$(curl --fail --silent --show-error --location "https://api.github.com/repos/$repo/commits/$ref" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sha"])') || { echo "[pins] cannot resolve public source tag $ref" >&2; exit 1; }
      test "$resolved" = "$pin" || { echo "[pins] moving source drift: $ref resolves to $resolved, registry records $pin" >&2; exit 1; }
      ;;
    *) test "$ref" = "$pin" || { echo "[pins] source commit drift: $ref != $pin" >&2; exit 1; } ;;
  esac
done < validation/xr-sources.tsv

python3 scripts/check-roots.py validation/roots.txt

echo '[render] build registered roots'
: > "$tmp/rendered.yaml"
while IFS= read -r root; do
  case "$root" in ''|'#'*) continue ;; esac
  kfile=
  for candidate in "$root/kustomization.yaml" "$root/kustomization.yml" "$root/Kustomization"; do test ! -f "$candidate" || { kfile=$candidate; break; }; done
  test -n "$kfile" || { echo "[render] missing Kustomization: $root" >&2; exit 1; }
  if [ "$root" = crossplane/01-tls-ingress/compositions ]; then
    kustomize build "$root" > "$tmp/root.yaml" || { echo "[render] failed: $root" >&2; exit 1; }
    test ! -s "$tmp/root.yaml" || { echo "[render] declared empty scaffold now renders resources: $root" >&2; exit 1; }
    echo '[render] verified declared empty 01 compositions scaffold'; continue
  fi
  echo "[render] $root"
  kustomize build "$root" > "$tmp/root.yaml" || { echo "[render] failed: $root" >&2; exit 1; }
  cat "$tmp/root.yaml" >> "$tmp/rendered.yaml"
  printf '\n---\n' >> "$tmp/rendered.yaml"
done < validation/roots.txt
# Validate every tracked YAML API object, including standalone files. Rendered
# resources may therefore be checked twice; coverage is explicit, never inferred.
python3 scripts/tracked-yaml.py > "$tmp/tracked-yaml.yaml"
cat "$tmp/tracked-yaml.yaml" >> "$tmp/rendered.yaml"
test -s "$tmp/rendered.yaml" || { echo '[render] no output' >&2; exit 1; }

echo '[partition] classify exact XRs and enforce XRD scope'
python3 scripts/partition-manifests.py validation/xr-sources.tsv "$tmp/rendered.yaml" "$tmp/general.yaml" "$tmp/xrs.tsv" "$tmp/xr-rendered.yaml"

echo '[schema] prepare pinned generic CRD schema and referenced definitions'
mkdir -p "$tmp/schemas"
curl --fail --silent --show-error --location 'https://raw.githubusercontent.com/yannh/kubernetes-json-schema/f7d855e49c34b039c9ef2196444910275e31e09e/master-local/customresourcedefinition-apiextensions-v1.json' -o "$tmp/schemas/customresourcedefinition-apiextensions-v1.json"
curl --fail --silent --show-error --location 'https://raw.githubusercontent.com/yannh/kubernetes-json-schema/f7d855e49c34b039c9ef2196444910275e31e09e/master-local/_definitions.json' -o "$tmp/schemas/_definitions.json"
test "$(shasum -a 256 "$tmp/schemas/customresourcedefinition-apiextensions-v1.json" | awk '{print $1}')" = 95e10ef81ae70e513186795e21d4b2717fbbef4e2d4eac3085579cfaa0d591ed || { echo '[schema] CRD schema checksum mismatch' >&2; exit 1; }
test "$(shasum -a 256 "$tmp/schemas/_definitions.json" | awk '{print $1}')" = 612e45c0738917da308c2b7eacd266c8d9b26a59dfdecbe48269b1434029e17c || { echo '[schema] definitions checksum mismatch' >&2; exit 1; }

echo '[schema] kubeconform strict against pinned Kubernetes and CRD schemas'
kubeconform -strict -summary -kubernetes-version 1.36.0 \
  -schema-location 'https://raw.githubusercontent.com/yannh/kubernetes-json-schema/f7d855e49c34b039c9ef2196444910275e31e09e/{{.NormalizedKubernetesVersion}}-standalone-strict/{{.ResourceKind}}{{.KindSuffix}}.json' \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/3eb90d47aba8d61919d4419dd38301536e32a94b/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  -schema-location "$tmp/schemas/{{.ResourceKind}}{{.KindSuffix}}.json" \
  -schema-location 'https://raw.githubusercontent.com/yannh/kubernetes-json-schema/f7d855e49c34b039c9ef2196444910275e31e09e/{{.NormalizedKubernetesVersion}}-standalone-strict/{{.ResourceKind}}.json' "$tmp/general.yaml"

echo '[crossplane] validate mapped XR files against same-pin XRDs'
while IFS='|' read -r apiversion kind source pin xrd witness ref repo; do
  case "$apiversion" in ''|'#'*) continue ;; esac
  test -f "$source" || { echo "[crossplane] missing XR: $source" >&2; exit 1; }
  xrdfile="$tmp/$(basename "$(dirname "$source")")-xrd.yaml"
  url="https://raw.githubusercontent.com/$repo/$pin/$xrd"
  curl --fail --silent --show-error --location "$url" -o "$xrdfile" || { echo "[crossplane] failed XRD fetch: $url" >&2; exit 1; }
  python3 scripts/check-xrd-scope.py "$xrdfile" "$apiversion" "$kind"
  crossplane resource validate "$xrdfile" "$source" --crossplane-image= --error-on-missing-schemas --cache-dir="$tmp/crossplane-cache"
done < validation/xr-sources.tsv

echo '[coverage] verify every excluded rendered XR has a mapped, validated source'
python3 scripts/check-xr-coverage.py validation/xr-sources.tsv "$tmp/xrs.tsv" "$tmp/xr-rendered.yaml"

echo '[secrets] scan tracked working tree only (redacted)'
python3 - "$tmp/tracked" <<'PY'
import os, pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
for raw in subprocess.check_output(["git", "ls-files", "-z"]).split(b"\0"):
    if not raw:
        continue
    rel = pathlib.PurePosixPath(os.fsdecode(raw))
    if rel.is_absolute() or ".." in rel.parts:
        raise SystemExit("[secrets] unsafe tracked path")
    source = pathlib.Path(str(rel))
    if source.is_symlink():
        raise SystemExit(f"[secrets] refusing tracked symlink: {rel}")
    if not source.is_file():
        raise SystemExit(f"[secrets] tracked file missing from working tree: {rel}")
    target = root.joinpath(*rel.parts)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(source.read_bytes())
PY
gitleaks dir --redact --no-banner "$tmp/tracked"
echo '[done] public manifest validation passed'
