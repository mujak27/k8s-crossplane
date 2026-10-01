#!/usr/bin/env bash
# Run with bash; never source this script or enable tracing around credentials.
set +x
set -euo pipefail

command -v kubectl >/dev/null
key_path=${1:?Usage: bash bootstrap/configure-private-repo.sh /path/to/deploy-key}
[[ -r "$key_path" ]] || { printf 'Private key is not readable.\n' >&2; exit 1; }
printf 'Cluster context: %s\n' "$(kubectl config current-context)"
read -r -p 'Configure private repository access in this cluster? [y/N] ' confirm
[[ "$confirm" == y || "$confirm" == Y ]] || exit 1
kubectl -n argocd get namespace argocd >/dev/null

# Register the corresponding public key as a read-only GitHub deploy key first.
# Private key contents stay out of command-line arguments and Git.
kubectl -n argocd create secret generic k8s-crossplane-private-repository \
  --from-literal=type=git \
  --from-literal=url=git@github.com:mujak27/k8s-crossplane-private.git \
  --from-file=sshPrivateKey="$key_path" \
  --dry-run=client -o json \
  | kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o json \
  | kubectl apply --server-side --field-manager=private-repo-bootstrap -f -

printf 'Credentials configured. Check Settings > Repositories in Argo CD for connection status.\n'
