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
export VALIDATION_TMP="$tmp"

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
while IFS='|' read -r apiversion kind source pin xrd witness ref; do
  case "$apiversion" in ''|'#'*) continue ;; esac
  python3 scripts/check-pin-witness.py "$witness" "$ref" || { echo "[pins] local pin drift for $source ($ref not in deployed source field at $witness)" >&2; exit 1; }
  case "$source" in
    crossplane/01-tls-ingress/*|crossplane/02-tls-ingress-custom/*|crossplane/03-istio-secure-egress/*) repo=mujak27/crossplane-compilations ;;
    *) echo "[pins] invalid source mapping: $source" >&2; exit 1 ;;
  esac
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
  test -f "$root/kustomization.yaml" || { echo "[render] missing root: $root" >&2; exit 1; }
  if [ "$root" = crossplane/01-tls-ingress/compositions ]; then
    test "$(find "$root" -type f ! -name 'kustomization.yaml' ! -name 'kustomization.yml' ! -name Kustomization | wc -l | tr -d ' ')" = 0 || { echo "[render] expected empty scaffold, found files under $root" >&2; exit 1; }
    echo '[render] verified empty 01 compositions scaffold'; continue
  fi
  echo "[render] $root"
  kustomize build "$root" >> "$tmp/rendered.yaml" || { echo "[render] failed: $root" >&2; exit 1; }
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
while IFS='|' read -r apiversion kind source pin xrd witness ref; do
  case "$apiversion" in ''|'#'*) continue ;; esac
  python3 scripts/check-pin-witness.py "$witness" "$ref" || { echo "[crossplane] pin drift for $source ($ref not in deployed source field at $witness)" >&2; exit 1; }
  case "$source" in
    crossplane/01-tls-ingress/*) repo=mujak27/crossplane-compilations ;;
    crossplane/02-tls-ingress-custom/*) repo=mujak27/crossplane-compilations ;;
    crossplane/03-istio-secure-egress/*) repo=mujak27/crossplane-compilations ;;
    *) echo "[crossplane] invalid source mapping: $source" >&2; exit 1 ;;
  esac
  test -f "$source" || { echo "[crossplane] missing XR: $source" >&2; exit 1; }
  case "$ref" in
    *-v[0-9]*)
      resolved=$(curl --fail --silent --show-error --location "https://api.github.com/repos/$repo/commits/$ref" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sha"])') || { echo "[crossplane] cannot resolve public source tag $ref" >&2; exit 1; }
      test "$resolved" = "$pin" || { echo "[crossplane] source tag drift: $ref resolves to $resolved, expected $pin" >&2; exit 1; }
      ;;
    *) test "$ref" = "$pin" || { echo "[crossplane] source commit drift: $ref != $pin" >&2; exit 1; } ;;
  esac
  xrdfile="$tmp/$(basename "$(dirname "$source")")-xrd.yaml"
  url="https://raw.githubusercontent.com/$repo/$pin/$xrd"
  curl --fail --silent --show-error --location "$url" -o "$xrdfile" || { echo "[crossplane] failed XRD fetch: $url" >&2; exit 1; }
  python3 scripts/check-xrd-scope.py "$xrdfile" "$apiversion" "$kind"
  crossplane resource validate "$xrdfile" "$source" --crossplane-image= --error-on-missing-schemas --cache-dir="$tmp/crossplane-cache"
done < validation/xr-sources.tsv

echo '[coverage] verify every excluded rendered XR has a mapped, validated source'
python3 scripts/check-xr-coverage.py validation/xr-sources.tsv "$tmp/xrs.tsv" "$tmp/xr-rendered.yaml"

echo '[secrets] scan tracked working tree only (redacted)'
tar -cf "$tmp/tracked.tar" -T /dev/null
git ls-files | while IFS= read -r file; do
  if [ -f "$file" ]; then tar -rf "$tmp/tracked.tar" "$file"; fi
done
mkdir "$tmp/tracked" && tar -xf "$tmp/tracked.tar" -C "$tmp/tracked"
gitleaks dir --redact --no-banner "$tmp/tracked"
echo '[done] public manifest validation passed'
