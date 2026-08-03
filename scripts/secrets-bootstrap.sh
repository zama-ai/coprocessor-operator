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

# Namespaces from the given list that do not yet hold the named secret.
# In dry-run every namespace is reported missing so all manifests are printed.
missing_namespaces() {
  local secret=$1; shift
  local ns missing=""
  for ns in "$@"; do
    if [[ "$DRY_RUN" == "true" ]] || ! kubectl get secret "$secret" --namespace "$ns" &>/dev/null; then
      missing="$missing $ns"
    fi
  done
  echo "$missing"
}

# Read a password back out of an existing secret so a partially-applied
# bootstrap can be completed without desyncing the other namespaces.
secret_password() {
  local secret=$1 namespace=$2
  kubectl get secret "$secret" --namespace "$namespace" \
    -o go-template='{{.data.password | base64decode}}'
}

validate_rpc_url() {
  local label=$1 url=$2 scheme=$3
  case "$url" in
    "$scheme"://*) ;;
    *) echo "  ✗ $label must start with ${scheme}://"; exit 1 ;;
  esac

  # Mainnet-only guard: catches a leftover testnet endpoint pasted into a mainnet deploy.
  if [[ "$CLUSTER_ENV" == "mainnet" ]]; then
    case "$url" in
      *sepolia*|*amoy*|*testnet*)
        echo "  ⚠ $label looks like a TESTNET endpoint but the target cluster is mainnet."
        read -rp "    Type 'yes' to use it anyway: " CONFIRM
        [[ "$CONFIRM" == "yes" ]] || { echo "  aborted — no changes made"; exit 1; }
        ;;
    esac
  fi
}

# =============================================================================
#  Pre-flight
# =============================================================================
CONTEXT=$(kubectl config current-context 2>/dev/null || true)
case "$CONTEXT" in
  *mainnet*) CLUSTER_ENV=mainnet ;;
  *testnet*) CLUSTER_ENV=testnet ;;
  *)         CLUSTER_ENV=unknown ;;
esac

if [[ "$DRY_RUN" == "false" ]]; then
  echo ""
  echo "  Target cluster context: ${CONTEXT:-<none>}"
  echo "  Detected environment:   $CLUSTER_ENV"
  read -rp "  Type 'yes' to continue: " CONFIRM
  [[ "$CONFIRM" == "yes" ]] || { echo "  aborted — no changes made"; exit 1; }

  MISSING_NS=""
  for NS in coproc coproc-admin monitoring gw-blockchain eth-blockchain polygon-blockchain kube-system karpenter; do
    kubectl get namespace "$NS" &>/dev/null || MISSING_NS="$MISSING_NS $NS"
  done
  if [[ -n "$MISSING_NS" ]]; then
    echo "  ✗ missing namespaces:$MISSING_NS"
    echo "    These are created by the k8s_coprocessor_deps Terraform layer — apply it before running this script."
    exit 1
  fi
fi

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
COPROCESSOR_MISSING=$(missing_namespaces coprocessor-user-rds-credentials coproc coproc-admin gw-blockchain eth-blockchain polygon-blockchain)
if [[ -z "$COPROCESSOR_MISSING" ]]; then
  echo "  skipping — secret coprocessor-user-rds-credentials already exist"
else
  if [[ "$DRY_RUN" == "false" ]] && kubectl get secret coprocessor-user-rds-credentials --namespace coproc &>/dev/null; then
    COPROCESSOR_PASS=$(secret_password coprocessor-user-rds-credentials coproc)
    echo "  reusing existing coprocessor_user password"
  fi

  echo ""
  echo "  coprocessor-user-rds-credentials"
  for NS in $COPROCESSOR_MISSING; do
    apply_secret coprocessor-user-rds-credentials "$NS" \
      --from-literal=username="coprocessor_user" \
      --from-literal=password="$COPROCESSOR_PASS"
  done
fi

# postgres_exporter
POSTGRES_EXPORTER_MISSING=$(missing_namespaces postgres-exporter-rds-credentials coproc-admin)
POSTGRES_EXPORTER_CONFIG_MISSING=$(missing_namespaces postgres-exporter-config monitoring)
if [[ -z "$POSTGRES_EXPORTER_MISSING" && -z "$POSTGRES_EXPORTER_CONFIG_MISSING" ]]; then
  echo "  skipping — secret postgres-exporter-rds-credentials already exist"
else
  if [[ "$DRY_RUN" == "false" ]] && kubectl get secret postgres-exporter-rds-credentials --namespace coproc-admin &>/dev/null; then
    POSTGRES_EXPORTER_PASS=$(secret_password postgres-exporter-rds-credentials coproc-admin)
    echo "  reusing existing postgres_exporter password"
  fi

  if [[ -n "$POSTGRES_EXPORTER_MISSING" ]]; then
    echo ""
    echo "  postgres-exporter-rds-credentials (coproc-admin ns only — consumed by db-user-setup Job)"
    apply_secret postgres-exporter-rds-credentials coproc-admin \
      --from-literal=username="postgres_exporter" \
      --from-literal=password="$POSTGRES_EXPORTER_PASS"
  fi

  if [[ -n "$POSTGRES_EXPORTER_CONFIG_MISSING" ]]; then
    echo ""
    echo "  postgres-exporter-config (monitoring ns — consumed by prometheus-postgres-exporter)"
    apply_secret postgres-exporter-config monitoring \
      --from-literal=DATA_SOURCE_NAME="postgresql://postgres_exporter:${POSTGRES_EXPORTER_PASS}@coprocessor-database.coproc.svc.cluster.local:5432/coprocessor?sslmode=require"
  fi
fi

# sql_exporter
SQL_EXPORTER_MISSING=$(missing_namespaces sql-exporter-rds-credentials coproc-admin)
SQL_EXPORTER_CONFIG_MISSING=$(missing_namespaces sql-exporter-config monitoring)
if [[ -z "$SQL_EXPORTER_MISSING" && -z "$SQL_EXPORTER_CONFIG_MISSING" ]]; then
  echo "  skipping — secret sql-exporter-rds-credentials already exist"
else
  if [[ "$DRY_RUN" == "false" ]] && kubectl get secret sql-exporter-rds-credentials --namespace coproc-admin &>/dev/null; then
    SQL_EXPORTER_PASS=$(secret_password sql-exporter-rds-credentials coproc-admin)
    echo "  reusing existing sql_exporter password"
  fi

  if [[ -n "$SQL_EXPORTER_MISSING" ]]; then
    echo ""
    echo "  sql-exporter-rds-credentials (coproc-admin ns only — consumed by db-user-setup Job)"
    apply_secret sql-exporter-rds-credentials coproc-admin \
      --from-literal=username="sql_exporter" \
      --from-literal=password="$SQL_EXPORTER_PASS"
  fi

  if [[ -n "$SQL_EXPORTER_CONFIG_MISSING" ]]; then
    echo ""
    echo "  sql-exporter-config (monitoring ns — consumed by sql-exporter)"
    apply_secret sql-exporter-config monitoring \
      --from-literal=DATA_SOURCE_NAME="postgresql://sql_exporter:${SQL_EXPORTER_PASS}@coprocessor-database.coproc.svc.cluster.local:5432/coprocessor?sslmode=require"
  fi
fi

# =============================================================================
#  Registry credentials
# =============================================================================
echo ""
echo "[ 2/6 ] Registry credentials"
echo "        (hub.zama.org service account credentials)"

REGISTRY_MISSING=$(missing_namespaces registry-credentials coproc coproc-admin gw-blockchain eth-blockchain polygon-blockchain kube-system monitoring karpenter)
if [[ -z "$REGISTRY_MISSING" ]]; then
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
  for NS in $REGISTRY_MISSING; do
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

ETHEREUM_MISSING=$(missing_namespaces rpc-credentials eth-blockchain gw-blockchain coproc)
if [[ -z "$ETHEREUM_MISSING" ]]; then
  echo "  skipping — secrets already exist"
else
  echo ""
  if [[ -z "${ETHEREUM_RPC_URL:-}" ]]; then
    read -rsp "  Ethereum RPC URL:     " ETHEREUM_RPC_URL; echo
  fi
  if [[ -z "${ETHEREUM_RPC_WS_URL:-}" ]]; then
    read -rsp "  Ethereum RPC WS URL:  " ETHEREUM_RPC_WS_URL; echo
  fi

  validate_rpc_url "Ethereum RPC URL"    "$ETHEREUM_RPC_URL"    https
  validate_rpc_url "Ethereum RPC WS URL" "$ETHEREUM_RPC_WS_URL" wss

  echo ""
  echo "  rpc-credentials"
  for NS in $ETHEREUM_MISSING; do
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

POLYGON_MISSING=$(missing_namespaces rpc-credentials polygon-blockchain)
if [[ -z "$POLYGON_MISSING" ]]; then
  echo "  skipping — secrets already exist"
else
  echo ""
  if [[ -z "${POLYGON_RPC_URL:-}" ]]; then
    read -rsp "  Polygon RPC URL:      " POLYGON_RPC_URL; echo
  fi
  if [[ -z "${POLYGON_RPC_WS_URL:-}" ]]; then
    read -rsp "  Polygon RPC WS URL:   " POLYGON_RPC_WS_URL; echo
  fi

  validate_rpc_url "Polygon RPC URL"    "$POLYGON_RPC_URL"    https
  validate_rpc_url "Polygon RPC WS URL" "$POLYGON_RPC_WS_URL" wss

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

CONDUIT_MISSING=$(missing_namespaces conduit-credentials gw-blockchain)
if [[ -z "$CONDUIT_MISSING" ]]; then
  echo "  skipping — secrets already exist"
else
  echo ""
  if [[ -z "${CONDUIT_RPC_URL:-}" ]]; then
    read -rsp "  Conduit RPC URL:      " CONDUIT_RPC_URL; echo
  fi
  if [[ -z "${CONDUIT_RPC_WS_URL:-}" ]]; then
    read -rsp "  Conduit RPC WS URL:   " CONDUIT_RPC_WS_URL; echo
  fi

  validate_rpc_url "Conduit RPC URL"    "$CONDUIT_RPC_URL"    https
  validate_rpc_url "Conduit RPC WS URL" "$CONDUIT_RPC_WS_URL" wss

  echo ""
  echo "  conduit-credentials"
  apply_secret conduit-credentials gw-blockchain \
    --from-literal=conduit-rpc-url="$CONDUIT_RPC_URL" \
    --from-literal=conduit-rpc-ws-url="$CONDUIT_RPC_WS_URL"
fi

echo ""
echo $'\e[32m✓ Done!\e[0m'
