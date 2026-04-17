#!/bin/bash
set -euo pipefail

# =============================================================================
#  Coprocessor Secret Bootstrap
#
#  Creates Kubernetes secrets required by the Coprocessor stack.
#  RDS user passwords are generated automatically and stored only in K8s Secrets.
#  Idempotent — safe to re-run.
#
#  Usage:
#    ./secrets-bootstrap.sh            Apply secrets to the cluster
#    ./secrets-bootstrap.sh --dry-run  Print manifests without applying
#
#  Environment variables (optional — skip interactive prompts when set):
#    REGISTRY_USER, REGISTRY_PASS
#    PROMETHEUS_USER, PROMETHEUS_PASS
#    LOKI_USER, LOKI_PASS
#    OTLP_USER, OTLP_PASS
#
#  Examples:
#    source .env && ./secrets-bootstrap.sh
#    REGISTRY_USER=robot REGISTRY_PASS=token ./secrets-bootstrap.sh
#
#  Prerequisites:
#    - kubectl configured against the target cluster
#    - openssl available (macOS/Linux default)
#    - Namespaces already created (via Terraform)
# =============================================================================

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
  echo "  (dry-run mode — no secrets will be written)"
fi

apply_secret() {
  local name=$1 namespace=$2; shift 2
  if [[ "$DRY_RUN" == "true" ]]; then
    kubectl create secret generic "$name" --namespace "$namespace" "$@" \
      --dry-run=client -o yaml
  else
    kubectl create secret generic "$name" --namespace "$namespace" "$@" \
      --dry-run=client -o yaml | kubectl apply -f - > /dev/null
    echo "    ✓ $namespace/$name"
  fi
}

# =============================================================================
#  RDS user passwords (auto-generated, skipped if already exist)
# =============================================================================
echo ""
echo "[ 1/3 ] RDS user passwords"

if [[ "$DRY_RUN" == "false" ]] && kubectl get secret coprocessor-user-rds-credentials --namespace coproc &>/dev/null; then
  echo "  skipping — secrets already exist"
else
  # ~40 char alphanumeric (32 random bytes base64-encoded, symbols stripped)
  COPROCESSOR_PASS=$(openssl rand -base64 32 | tr -d '/+=')
  EXPORTER_PASS=$(openssl rand -base64 32 | tr -d '/+=')

  echo ""
  echo "  coprocessor-user-rds-credentials"
  for NS in coproc coproc-admin gw-blockchain eth-blockchain; do
    apply_secret coprocessor-user-rds-credentials "$NS" \
      --from-literal=username="coprocessor_user" \
      --from-literal=password="$COPROCESSOR_PASS"
  done

  echo ""
  echo "  postgres-exporter-rds-credentials (coproc-admin only — consumed by db-user-setup Job)"
  apply_secret postgres-exporter-rds-credentials coproc-admin \
    --from-literal=username="postgres_exporter" \
    --from-literal=password="$EXPORTER_PASS"

  echo ""
  echo "  postgres-exporter-config (monitoring — consumed by prometheus-postgres-exporter)"
  apply_secret postgres-exporter-config monitoring \
    --from-literal=DATA_SOURCE_NAME="postgresql://postgres_exporter:${EXPORTER_PASS}@coprocessor-database.coproc.svc.cluster.local:5432/coprocessor?sslmode=require"
fi

# =============================================================================
#  Registry credentials
# =============================================================================
echo ""
echo "[ 2/3 ] Registry credentials"
echo "        (hub.zama.org service account credentials)"
echo ""

REGISTRY_SERVER="hub.zama.org"
if [[ -z "${REGISTRY_USER:-}" ]]; then
  read -rsp "  Registry username:  " REGISTRY_USER; echo
fi
if [[ -z "${REGISTRY_PASS:-}" ]]; then
  read -rsp "  Registry password:  " REGISTRY_PASS; echo
fi

echo ""
echo "  registry-credentials"
for NS in coproc coproc-admin gw-blockchain eth-blockchain kube-system monitoring karpenter; do
  if [[ "$DRY_RUN" == "true" ]]; then
    kubectl create secret docker-registry registry-credentials \
      --namespace "$NS" \
      --docker-server="$REGISTRY_SERVER" \
      --docker-username="$REGISTRY_USER" \
      --docker-password="$REGISTRY_PASS" \
      --dry-run=client -o yaml
  else
    kubectl create secret docker-registry registry-credentials \
      --namespace "$NS" \
      --docker-server="$REGISTRY_SERVER" \
      --docker-username="$REGISTRY_USER" \
      --docker-password="$REGISTRY_PASS" \
      --dry-run=client -o yaml | kubectl apply -f - > /dev/null
    echo "    ✓ $NS/registry-credentials"
  fi
done

# =============================================================================
#  Grafana Cloud credentials
# =============================================================================
echo ""
echo "[ 3/3 ] Grafana Cloud credentials"
echo "        (Provided by Zama)"
echo ""

if [[ -z "${PROMETHEUS_USER:-}" ]]; then
  read -rsp "  Prometheus username (ID):     " PROMETHEUS_USER; echo
fi
if [[ -z "${PROMETHEUS_PASS:-}" ]]; then
  read -rsp "  Prometheus password (token):  " PROMETHEUS_PASS; echo
fi

echo ""
if [[ -z "${LOKI_USER:-}" ]]; then
  read -rsp "  Loki username (ID):           " LOKI_USER; echo
fi
if [[ -z "${LOKI_PASS:-}" ]]; then
  read -rsp "  Loki password (token):        " LOKI_PASS; echo
fi

echo ""
if [[ -z "${OTLP_USER:-}" ]]; then
  read -rsp "  OTLP username (ID):           " OTLP_USER; echo
fi
if [[ -z "${OTLP_PASS:-}" ]]; then
  read -rsp "  OTLP password (token):        " OTLP_PASS; echo
fi

echo ""
echo "  grafana-cloud-credentials"
apply_secret grafana-cloud-credentials monitoring \
  --from-literal=prometheus-username="$PROMETHEUS_USER" \
  --from-literal=prometheus-password="$PROMETHEUS_PASS" \
  --from-literal=loki-username="$LOKI_USER" \
  --from-literal=loki-password="$LOKI_PASS" \
  --from-literal=otlp-username="$OTLP_USER" \
  --from-literal=otlp-password="$OTLP_PASS"

echo ""
echo $'\e[32m✓ Done!\e[0m'
