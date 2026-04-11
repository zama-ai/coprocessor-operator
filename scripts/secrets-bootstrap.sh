#!/bin/bash
set -euo pipefail

# =============================================================================
#  Coprocessor Secret Bootstrap
#
#  Creates all Kubernetes secrets required by the Coprocessor stack.
#  RDS user passwords are generated automatically and stored only in K8s Cecrets.
#  Idempotent — safe to re-run.
#
#  Prerequisites:
#    - kubectl configured against the target cluster
#    - openssl available (macOS/Linux default)
#    - Namespaces already created (via Terraform)
# =============================================================================

apply_secret() {
  local name=$1 namespace=$2; shift 2
  kubectl create secret generic "$name" --namespace "$namespace" "$@" \
    --dry-run=client -o yaml | kubectl apply -f - > /dev/null
  echo "    ✓ $namespace/$name"
}

# =============================================================================
#  RDS user passwords (auto-generated, skipped if already exist)
# =============================================================================
echo ""
echo "[ 1/3 ] RDS user passwords"

if kubectl get secret coprocessor-user-rds-credentials --namespace coproc &>/dev/null; then
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
fi

# =============================================================================
#  Registry credentials
# =============================================================================
echo ""
echo "[ 2/3 ] Registry credentials"
echo "        (hub.zama.org service account credentials)"
echo ""

read -rp  "  Registry server:    " REGISTRY_SERVER
read -rsp "  Registry username:  " REGISTRY_USER; echo
read -rsp "  Registry password:  " REGISTRY_PASS; echo

echo ""
echo "  registry-credentials"
for NS in coproc coproc-admin gw-blockchain eth-blockchain; do
  kubectl create secret docker-registry registry-credentials \
    --namespace "$NS" \
    --docker-server="$REGISTRY_SERVER" \
    --docker-username="$REGISTRY_USER" \
    --docker-password="$REGISTRY_PASS" \
    --dry-run=client -o yaml | kubectl apply -f - > /dev/null
  echo "    ✓ $NS/registry-credentials"
done

# =============================================================================
#  Grafana Cloud credentials
# =============================================================================
echo ""
echo "[ 3/3 ] Grafana Cloud credentials"
echo "        (Provided by Zama)"
echo ""

read -rsp "  Prometheus username (ID):     " PROMETHEUS_USER; echo
read -rsp "  Prometheus password (token):  " PROMETHEUS_PASS; echo

echo ""
read -rsp "  Loki username (ID):           " LOKI_USER; echo
read -rsp "  Loki password (token):        " LOKI_PASS; echo

echo ""
read -rsp "  Tempo username (ID):          " OTLP_USER; echo
read -rsp "  Tempo password (token):       " OTLP_PASS; echo

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
