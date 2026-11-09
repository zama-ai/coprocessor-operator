#!/bin/bash
set -euo pipefail

# =============================================================================
#  New Blockchain Bootstrap
#
#  This script will be deprecated in a future release. New-chain secret
#  provisioning is now owned by secrets-bootstrap.sh, which provisions missing
#  database, registry and chain-specific RPC secrets. Add the new chain's
#  namespace and RPC provisioning there before running it.
#
#  Retained for compatibility: copies the existing coprocessor_user RDS and
#  registry credential secrets from coproc into the supplied target namespaces.
#  secrets-bootstrap.sh also reuses the existing coprocessor_user password from
#  coproc when populating missing destinations during normal execution.
#  Idempotent — safe to re-run.
#
#  Usage:
#    ./new-blockchain-bootstrap.sh <target-ns> [<target-ns>...]
#    ./new-blockchain-bootstrap.sh --dry-run <target-ns> [<target-ns>...]
#
#  Examples:
#    ./new-blockchain-bootstrap.sh polygon-blockchain
#    ./new-blockchain-bootstrap.sh polygon-blockchain arbitrum-blockchain
#
#  Prerequisites:
#    - kubectl configured against the target cluster
#    - jq available
#    - source secret already exists (created by secrets-bootstrap.sh)
#    - target namespaces already created (via Terraform)
# =============================================================================

SECRET_NAMES=("coprocessor-user-rds-credentials" "registry-credentials")
SOURCE_NS="coproc"

DRY_RUN=false
TARGETS=()
for arg in "$@"; do
  if [[ "$arg" == "--dry-run" ]]; then
    DRY_RUN=true
    echo "  (dry-run mode — no secrets will be written)"
  else
    TARGETS+=("$arg")
  fi
done

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  echo "error: provide at least one target namespace" >&2
  echo "usage: $0 [--dry-run] <target-ns> [<target-ns>...]" >&2
  exit 1
fi

for SECRET_NAME in "${SECRET_NAMES[@]}"; do
  if ! kubectl get secret "$SECRET_NAME" --namespace "$SOURCE_NS" &>/dev/null; then
    echo "error: source secret $SOURCE_NS/$SECRET_NAME not found" >&2
    echo "       run secrets-bootstrap.sh first" >&2
    exit 1
  fi
done

for SECRET_NAME in "${SECRET_NAMES[@]}"; do
  # Pull the source secret and strip cluster-managed metadata so it can be
  # re-created in another namespace.
  MANIFEST=$(kubectl get secret "$SECRET_NAME" --namespace "$SOURCE_NS" -o json \
    | jq 'del(.metadata.namespace, .metadata.resourceVersion, .metadata.uid,
              .metadata.creationTimestamp, .metadata.ownerReferences,
              .metadata.managedFields, .status,
              .metadata.annotations."kubectl.kubernetes.io/last-applied-configuration")')

  echo ""
  echo "Fanning out $SECRET_NAME from $SOURCE_NS to: ${TARGETS[*]}"
  for NS in "${TARGETS[@]}"; do
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "$MANIFEST" | jq --arg ns "$NS" '.metadata.namespace = $ns'
    else
      echo "$MANIFEST" | kubectl apply --namespace "$NS" -f - > /dev/null
      echo "    ✓ $NS/$SECRET_NAME"
    fi
  done
done

echo ""
echo $'\e[32m✓ Done!\e[0m'
