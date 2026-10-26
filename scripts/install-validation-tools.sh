#!/bin/sh
set -eu
dest=${1:-"${HOME}/.local/k8s-crossplane-validation/bin"}
mkdir -p "$dest"
os=$(uname -s | tr '[:upper:]' '[:lower:]')
arch=$(uname -m)
case "$arch" in x86_64|amd64) arch=amd64 ;; arm64|aarch64) arch=arm64 ;; *) echo "unsupported architecture: $arch" >&2; exit 1 ;; esac
case "$os-$arch" in
  darwin-amd64) suffix=darwin_amd64; kube=kubeconform-darwin-amd64.tar.gz; gl=gitleaks_8.24.2_darwin_x64.tar.gz; ghash=bc3c46f8039ba716ba8461fa6745c9d1cfb90ca2f5f881d8d0cf66b7ba7b742c; khash=3432be97f9fb4899148bf2485ccf9080e5e7702758eb16c92cd2f2f335e12a03; vhash=3b5324ac4fd38ac60a49823b4051ff42ff7eb70144f1e9741fed1d14bc4fdb4e ;;
  darwin-arm64) suffix=darwin_arm64; kube=kubeconform-darwin-arm64.tar.gz; gl=gitleaks_8.24.2_darwin_arm64.tar.gz; ghash=90d13686937ac7429b97a3acbf1e1d0ce90d92ae2d0cf46a690bd8ae5230bea0; khash=cbb47d938a8d18eb5f79cb33663b2cecdee0c8ac0bf562ebcfca903df5f0802f; vhash=791d9497d2973d4af17c9c0c2b3991ce82e61d1a2bf79f4ef78dd9dce25a6d3d ;;
  linux-amd64) suffix=linux_amd64; kube=kubeconform-linux-amd64.tar.gz; gl=gitleaks_8.24.2_linux_x64.tar.gz; ghash=fa0500f6b7e41d28791ebc680f5dd9899cd42b58629218a5f041efa899151a8e; khash=95f14e87aa28c09d5941f11bd024c1d02fdc0303ccaa23f61cef67bc92619d73; vhash=54e4031ddc4e7fc59e408da29e7c646e8e57b8088c51b84b3df0864f47b5148f ;;
  linux-arm64) suffix=linux_arm64; kube=kubeconform-linux-arm64.tar.gz; gl=gitleaks_8.24.2_linux_arm64.tar.gz; ghash=574a6d52573c61173add7ddb5e3cc68c0e82cb0735818a1eeb9a0a2de1643fbc; khash=dc82f79bb03c5479b1ae5fd4af221e4b5a3111f62bf01a2795d9c5c20fa96644; vhash=ad8ab62d4f6d59a8afda0eec4ba2e5cd2f86bf1afeea4b78d06daac945eb0660 ;;
  *) echo "unsupported platform: $os-$arch" >&2; exit 1 ;;
esac
tmp=$(mktemp -d "${TMPDIR:-/tmp}/validation-tools.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
fetch() {
  curl --fail --silent --show-error --location "$1" -o "$tmp/$2"
  if command -v sha256sum >/dev/null 2>&1; then hashcmd=sha256sum; else hashcmd='shasum -a 256'; fi
  actual=$(eval "$hashcmd '$tmp/$2'" | awk '{print $1}')
  test "$actual" = "$3" || { echo "checksum mismatch for $2" >&2; exit 1; }
}
fetch "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv5.6.0/kustomize_v5.6.0_${suffix}.tar.gz" kustomize.tgz "$vhash"
tar -xzf "$tmp/kustomize.tgz" -C "$tmp" kustomize
install "$tmp/kustomize" "$dest/kustomize"
fetch "https://github.com/yannh/kubeconform/releases/download/v0.6.7/$kube" kubeconform.tgz "$khash"
tar -xzf "$tmp/kubeconform.tgz" -C "$tmp" kubeconform
install "$tmp/kubeconform" "$dest/kubeconform"
fetch "https://github.com/gitleaks/gitleaks/releases/download/v8.24.2/$gl" gitleaks.tgz "$ghash"
tar -xzf "$tmp/gitleaks.tgz" -C "$tmp" gitleaks
install "$tmp/gitleaks" "$dest/gitleaks"
case "$suffix" in
  darwin_arm64) crosshash=6e0e00370fce82299b931fabee8559eed8a79446172ceb2c24c6d1d76f76fb8c ;;
  linux_amd64) crosshash=065dd6b40c9ea5fc71e49900d5c924cc0bec7f58375922ddbde6b402f292347e ;;
  linux_arm64) crosshash=2ae3bfe43206e47454c2634dace1427bd35794f616619e8f34ce23ce5b811dfd ;;
  darwin_amd64) crosshash=b7d5749caff9c467ec03376b03772aaee2135aaf55f970a8a8fcbc341daf1a42 ;;
esac
fetch "https://cli.crossplane.io/stable/v2.5.0/bin/$suffix/crossplane" crossplane "$crosshash"
install "$tmp/crossplane" "$dest/crossplane"
echo "Pinned validation binaries installed in $dest (add this directory to PATH)."
