#!/usr/bin/env bash
# Deploy (or redeploy) the monitoring stack. Safe to run repeatedly: nothing is restarted
# on purpose. The k3s Helm controller upgrades a chart only when its HelmChart changes.
# Requires cluster/setup.sh to have been run once (GPU label + NVIDIA runtime class).
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
KUBECTL="${KUBECTL:-kubectl}"
NS=monitoring
LLM_ENV=../llm/.env

[[ -f .env ]] || { echo "Missing $PWD/.env — run: cp $PWD/.env.example $PWD/.env and set GRAFANA_ADMIN_PASSWORD"; exit 1; }

echo "==> Namespace"
$KUBECTL apply -f k8s/00-namespace.yaml

echo "==> Secrets + dashboards (generated from files)"
$KUBECTL -n "$NS" create secret generic grafana-admin --from-env-file=.env \
  --dry-run=client -o yaml | $KUBECTL apply -f -

# Copy of the LLM API key, so Prometheus can scrape llama-server's /metrics.
if grep -q '^LLAMA_API_KEY=' "$LLM_ENV" 2>/dev/null; then
  $KUBECTL -n "$NS" create secret generic llm-scrape \
    --from-env-file=<(grep '^LLAMA_API_KEY=' "$LLM_ENV") \
    --dry-run=client -o yaml | $KUBECTL apply -f -
else
  echo "Warning: no LLAMA_API_KEY in apps/llm/.env — the llm scrape target will fail until it exists."
fi

$KUBECTL -n "$NS" create configmap grafana-dashboards --from-file=dashboards/ \
  --dry-run=client -o yaml | $KUBECTL apply -f -

echo "==> Manifests (HelmCharts + GPU exporter)"
$KUBECTL apply -f k8s/

# HelmChart objects are installed asynchronously by helm-install-* Jobs in kube-system,
# so wait for each workload to appear before waiting for its rollout.
wait_for() {
  local obj=$1
  for _ in $(seq 60); do
    $KUBECTL -n "$NS" get "$obj" >/dev/null 2>&1 && break
    sleep 5
  done
  $KUBECTL -n "$NS" rollout status "$obj" --timeout=10m || {
    echo "Not ready: $obj. Check: $KUBECTL -n kube-system get jobs | grep helm-install"
    exit 1
  }
}

echo "==> Waiting for workloads"
wait_for deployment/prometheus-server
wait_for deployment/prometheus-kube-state-metrics
wait_for daemonset/prometheus-prometheus-node-exporter
wait_for daemonset/gpu-exporter
wait_for statefulset/loki
wait_for daemonset/alloy
wait_for deployment/grafana

$KUBECTL -n "$NS" get pods,svc
echo
echo "Grafana: http://<node-ip>:3000 (user/password from apps/monitoring/.env)"
