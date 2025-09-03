#!/usr/bin/env bash
# monitoring-deploy.sh
# A simple, idempotent shell installer for the Monitoring & Alerting Optimization stack
# (Prometheus Operator / kube-prometheus-stack, Grafana, Loki + Promtail)

set -euo pipefail
IFS=$'\n\t'

# Defaults - change these or provide via env/args
NAMESPACE=${NAMESPACE:-observability}
HELM_PROM_RELEASE=${HELM_PROM_RELEASE:-prometheus-stack}
HELM_GRAFANA_RELEASE=${HELM_GRAFANA_RELEASE:-grafana}
HELM_LOKI_RELEASE=${HELM_LOKI_RELEASE:-loki}
HELM_REPOS_ADDED=false
HELM_VALUES_DIR=${HELM_VALUES_DIR:-helm}
K8S_MANIFEST_DIR=${K8S_MANIFEST_DIR:-k8s}
WAIT_TIMEOUT=${WAIT_TIMEOUT:-300} # seconds to wait for deployments

print_help() {
  cat <<EOF
Usage: $0 [options]

Options:
  -n, --namespace NAME         Kubernetes namespace (default: ${NAMESPACE})
  --prom-release NAME          Helm release name for kube-prometheus-stack (default: ${HELM_PROM_RELEASE})
  --grafana-release NAME       Helm release name for Grafana (default: ${HELM_GRAFANA_RELEASE})
  --loki-release NAME          Helm release name for Loki (default: ${HELM_LOKI_RELEASE})
  --values-dir PATH            Directory with helm values files (default: ${HELM_VALUES_DIR})
  --manifests-dir PATH         Directory with kubernetes manifests (default: ${K8S_MANIFEST_DIR})
  -h, --help                   Show this help

Environment variables used:
  SLACK_WEBHOOK                (optional) Slack webhook URL; if set, this script will create a k8s secret named 'alertmanager-slack' in the namespace
  WAIT_TIMEOUT                 time in seconds to wait for pods to become ready (default: ${WAIT_TIMEOUT})

Example:
  NAMESPACE=observability ./monitoring-deploy.sh
EOF
}

# Simple arg parsing
while [[ ${#} -gt 0 ]]; do
  case "$1" in
    -n|--namespace)
      NAMESPACE="$2"; shift 2;;
    --prom-release)
      HELM_PROM_RELEASE="$2"; shift 2;;
    --grafana-release)
      HELM_GRAFANA_RELEASE="$2"; shift 2;;
    --loki-release)
      HELM_LOKI_RELEASE="$2"; shift 2;;
    --values-dir)
      HELM_VALUES_DIR="$2"; shift 2;;
    --manifests-dir)
      K8S_MANIFEST_DIR="$2"; shift 2;;
    -h|--help)
      print_help; exit 0;;
    *)
      echo "Unknown arg: $1"; print_help; exit 1;;
  esac
done

command_exists() { command -v "$1" >/dev/null 2>&1; }
for cmd in kubectl helm jq; do
  if ! command_exists "$cmd"; then
    echo "ERROR: required command '$cmd' not found in PATH. Install it and retry." >&2
    exit 2
  fi
done

# Ensure namespace exists
ensure_namespace() {
  echo "==> Ensuring namespace: ${NAMESPACE}"
  if kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
    echo "Namespace '${NAMESPACE}' already exists"
  else
    kubectl create namespace "${NAMESPACE}"
    echo "Created namespace '${NAMESPACE}'"
  fi
}

# Add helm repos
add_helm_repos() {
  echo "==> Adding Helm repos"
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true
  helm repo add grafana https://grafana.github.io/helm-charts || true
  helm repo add grafana-labs https://grafana.github.io/loki/charts || true
  helm repo update
  HELM_REPOS_ADDED=true
}

# Helm install/upgrade helper
helm_upgrade_install() {
  local release="$1"; shift
  local chart="$1"; shift
  local ns="$1"; shift
  local values_file="$1"; shift || true

  local extra_args=(--namespace "$ns" --atomic --wait)
  if [[ -n "${values_file:-}" && -f "${values_file}" ]]; then
    extra_args+=(--values "$values_file")
  fi

  echo "==> helm upgrade --install ${release} ${chart} ${extra_args[*]}"
  helm upgrade --install "${release}" "${chart}" "${extra_args[@]}"
}

# Create k8s secret for Alertmanager Slack webhook if provided via SLACK_WEBHOOK env
create_alertmanager_secret() {
  if [[ -z "${SLACK_WEBHOOK:-}" ]]; then
    echo "SLACK_WEBHOOK not set. Skipping creation of alertmanager secret."
    return
  fi
  echo "==> Creating Kubernetes secret for Alertmanager Slack webhook"
  kubectl -n "${NAMESPACE}" create secret generic alertmanager-slack \
    --from-literal=slack_url="${SLACK_WEBHOOK}" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "Created/updated secret 'alertmanager-slack' in namespace ${NAMESPACE}"
}

# Apply k8s manifests from directory
apply_manifests() {
  local dir="$1"
  if [[ -d "${dir}" ]]; then
    echo "==> Applying Kubernetes manifests from ${dir}"
    kubectl -n "${NAMESPACE}" apply -f "${dir}"
  else
    echo "Manifests dir '${dir}' not found; skipping"
  fi
}

# Wait for pods
wait_for_pods() {
  local ns="$1"
  local timeout=${2:-${WAIT_TIMEOUT}}
  echo "==> Waiting up to ${timeout}s for pods in namespace '${ns}' to be ready"
  local start
  start=$(date +%s)
  while true; do
    # count not ready pods
    local not_ready
    not_ready=$(kubectl -n "${ns}" get pods --no-headers 2>/dev/null | awk '{print $2" "$1}' | grep -v '\\/\\|1/1\|1/2\|2/2' || true)
    if [[ -z "${not_ready}" ]]; then
      echo "All pods appear ready in namespace ${ns}"
      return 0
    fi
    now=$(date +%s)
    if (( now - start > timeout )); then
      echo "Timeout: some pods are still not ready:" >&2
      kubectl -n "${ns}" get pods
      return 1
    fi
    echo "Pods not ready yet, sleeping 10s..."
    sleep 10
  done
}

main() {
  ensure_namespace
  add_helm_repos

  # Deploy Prometheus (kube-prometheus-stack)
  echo "==> Deploying Prometheus Operator (kube-prometheus-stack)"
  helm_upgrade_install "${HELM_PROM_RELEASE}" prometheus-community/kube-prometheus-stack "${NAMESPACE}" "${HELM_VALUES_DIR}/prometheus-values.yaml"

  # Deploy Grafana
  echo "==> Deploying Grafana"
  helm_upgrade_install "${HELM_GRAFANA_RELEASE}" grafana/grafana "${NAMESPACE}" "${HELM_VALUES_DIR}/grafana-values.yaml"

  # Deploy Loki (loki-stack)
  echo "==> Deploying Loki (loki-stack)"
  helm_upgrade_install "${HELM_LOKI_RELEASE}" grafana/loki-stack "${NAMESPACE}" "${HELM_VALUES_DIR}/loki-values.yaml"

  # Create secret for Alertmanager (if webhook provided)
  create_alertmanager_secret

  # Apply custom manifests: PrometheusRules, ServiceMonitors, Promtail, Grafana provisioning
  apply_manifests "${K8S_MANIFEST_DIR}"

  # Wait for pods
  wait_for_pods "${NAMESPACE}" || {
    echo "Warning: some pods failed to become ready within ${WAIT_TIMEOUT}s. Check 'kubectl -n ${NAMESPACE} get pods'"
  }

  echo "==> Post-deploy checks"
  # Try to fetch Prometheus endpoint service
  if kubectl -n "${NAMESPACE}" get svc prometheus-operated >/dev/null 2>&1; then
    echo "Prometheus service found: prometheus-operated.${NAMESPACE}"
  else
    echo "Prometheus service 'prometheus-operated' not found. Verify kube-prometheus-stack installation." >&2
  fi

  echo "Deployment finished. Useful commands:"
  cat <<EOF
- kubectl -n ${NAMESPACE} get pods
- kubectl -n ${NAMESPACE} get svc
- kubectl -n ${NAMESPACE} port-forward svc/prometheus-operated 9090:9090 &
- kubectl -n ${NAMESPACE} port-forward svc/${HELM_GRAFANA_RELEASE} 3000:80 &
- kubectl -n ${NAMESPACE} port-forward svc/loki 3100:3100 &
EOF

  echo "If you want, run the test-alert helper to trigger a test alert (not included by default)."
}

main "$@"
