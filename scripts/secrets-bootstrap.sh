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
#    ETHEREUM_RPC_URL, ETHEREUM_RPC_WS_URL
#    POLYGON_RPC_URL, POLYGON_RPC_WS_URL
#    CONDUIT_RPC_URL, CONDUIT_RPC_WS_URL
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
echo "[ 1/6 ] RDS user passwords"

# ~40 char alphanumeric (32 random bytes base64-encoded, symbols stripped)
gen_pass() { openssl rand -base64 32 | tr -d '/+='; }

COPROCESSOR_PASS=$(gen_pass)
POSTGRES_EXPORTER_PASS=$(gen_pass)
SQL_EXPORTER_PASS=$(gen_pass)

# coprocessor_user (fanned out to all coprocessor namespaces)
if [[ "$DRY_RUN" == "false" ]] && kubectl get secret coprocessor-user-rds-credentials --namespace coproc &>/dev/null; then
  echo "  skipping — secret coprocessor-user-rds-credentials already exist"
else
  echo ""
  echo "  coprocessor-user-rds-credentials"
  for NS in coproc coproc-admin gw-blockchain eth-blockchain polygon-blockchain; do
    apply_secret coprocessor-user-rds-credentials "$NS" \
      --from-literal=username="coprocessor_user" \
      --from-literal=password="$COPROCESSOR_PASS"
  done
fi

# postgres_exporter
if [[ "$DRY_RUN" == "false" ]] && kubectl get secret postgres-exporter-rds-credentials --namespace coproc-admin &>/dev/null; then
  echo "  skipping — secret postgres-exporter-rds-credentials already exist"
else
  echo ""
  echo "  postgres-exporter-rds-credentials (coproc-admin ns only — consumed by db-user-setup Job)"
  apply_secret postgres-exporter-rds-credentials coproc-admin \
    --from-literal=username="postgres_exporter" \
    --from-literal=password="$POSTGRES_EXPORTER_PASS"

  echo ""
  echo "  postgres-exporter-config (monitoring ns — consumed by prometheus-postgres-exporter)"
  apply_secret postgres-exporter-config monitoring \
    --from-literal=DATA_SOURCE_NAME="postgresql://postgres_exporter:${POSTGRES_EXPORTER_PASS}@coprocessor-database.coproc.svc.cluster.local:5432/coprocessor?sslmode=require"
fi

# sql_exporter
if [[ "$DRY_RUN" == "false" ]] && kubectl get secret sql-exporter-rds-credentials --namespace coproc-admin &>/dev/null; then
  echo "  skipping — secret sql-exporter-rds-credentials already exist"
else
  echo ""
  echo "  sql-exporter-rds-credentials (coproc-admin ns only — consumed by db-user-setup Job)"
  apply_secret sql-exporter-rds-credentials coproc-admin \
    --from-literal=username="sql_exporter" \
    --from-literal=password="$SQL_EXPORTER_PASS"

  echo ""
  echo "  sql-exporter-config (monitoring ns — consumed by sql-exporter)"
  apply_secret sql-exporter-config monitoring \
    --from-literal=DATA_SOURCE_NAME="postgresql://sql_exporter:${SQL_EXPORTER_PASS}@coprocessor-database.coproc.svc.cluster.local:5432/coprocessor?sslmode=require"
fi

# =============================================================================
#  Registry credentials
# =============================================================================
echo ""
echo "[ 2/6 ] Registry credentials"
echo "        (hub.zama.org service account credentials)"

if [[ "$DRY_RUN" == "false" ]] && kubectl get secret registry-credentials --namespace coproc &>/dev/null; then
  echo "  skipping — secrets already exist"
else
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
  for NS in coproc coproc-admin gw-blockchain eth-blockchain polygon-blockchain kube-system monitoring karpenter; do
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
fi

# =============================================================================
#  Grafana Cloud credentials
# =============================================================================
echo ""
echo "[ 3/6 ] Grafana Cloud credentials"
echo "        (Provided by Zama)"

if [[ "$DRY_RUN" == "false" ]] && kubectl get secret grafana-cloud-credentials --namespace monitoring &>/dev/null; then
  echo "  skipping — secrets already exist"
else
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
fi

# =============================================================================
#  RPC credentials
# =============================================================================
echo ""
echo "[ 4/6 ] RPC credentials"
echo "        (Ethereum RPC endpoints)"

if [[ "$DRY_RUN" == "false" ]] && kubectl get secret rpc-credentials --namespace coproc &>/dev/null; then
  echo "  skipping — secrets already exist"
else
  echo ""
  if [[ -z "${ETHEREUM_RPC_URL:-}" ]]; then
    read -rsp "  Ethereum RPC URL:     " ETHEREUM_RPC_URL; echo
  fi
  if [[ -z "${ETHEREUM_RPC_WS_URL:-}" ]]; then
    read -rsp "  Ethereum RPC WS URL:  " ETHEREUM_RPC_WS_URL; echo
  fi

  echo ""
  echo "  rpc-credentials"
  for NS in eth-blockchain gw-blockchain coproc; do
    apply_secret rpc-credentials "$NS" \
      --from-literal=ethereum-rpc-url="$ETHEREUM_RPC_URL" \
      --from-literal=ethereum-rpc-ws-url="$ETHEREUM_RPC_WS_URL"
  done
fi

# =============================================================================
#  Polygon RPC credentials
# =============================================================================
echo ""
echo "[ 5/6 ] Polygon RPC credentials"
echo "        (Polygon RPC endpoints)"

if [[ "$DRY_RUN" == "false" ]] && kubectl get secret rpc-credentials --namespace polygon-blockchain &>/dev/null; then
  echo "  skipping — secrets already exist"
else
  echo ""
  if [[ -z "${POLYGON_RPC_URL:-}" ]]; then
    read -rsp "  Polygon RPC URL:      " POLYGON_RPC_URL; echo
  fi
  if [[ -z "${POLYGON_RPC_WS_URL:-}" ]]; then
    read -rsp "  Polygon RPC WS URL:   " POLYGON_RPC_WS_URL; echo
  fi

  echo ""
  echo "  rpc-credentials"
  apply_secret rpc-credentials polygon-blockchain \
    --from-literal=polygon-rpc-url="$POLYGON_RPC_URL" \
    --from-literal=polygon-rpc-ws-url="$POLYGON_RPC_WS_URL"
fi

# =============================================================================
#  Conduit credentials
# =============================================================================
echo ""
echo "[ 6/6 ] Conduit credentials"
echo "        (Conduit RPC endpoints)"

if [[ "$DRY_RUN" == "false" ]] && kubectl get secret conduit-credentials --namespace gw-blockchain &>/dev/null; then
  echo "  skipping — secrets already exist"
else
  echo ""
  if [[ -z "${CONDUIT_RPC_URL:-}" ]]; then
    read -rsp "  Conduit RPC URL:      " CONDUIT_RPC_URL; echo
  fi
  if [[ -z "${CONDUIT_RPC_WS_URL:-}" ]]; then
    read -rsp "  Conduit RPC WS URL:   " CONDUIT_RPC_WS_URL; echo
  fi

  echo ""
  echo "  conduit-credentials"
  apply_secret conduit-credentials gw-blockchain \
    --from-literal=conduit-rpc-url="$CONDUIT_RPC_URL" \
    --from-literal=conduit-rpc-ws-url="$CONDUIT_RPC_WS_URL"
fi

echo ""
echo $'\e[32m✓ Done!\e[0m'
