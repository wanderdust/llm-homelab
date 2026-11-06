#!/usr/bin/env bash
# Deploy (or redeploy) the LLM server to k3s. Safe to run repeatedly.
set -euo pipefail
cd "$(dirname "$0")/.."

KUBECTL="${KUBECTL:-kubectl}"   # e.g. KUBECTL="sudo k3s kubectl" ./scripts/deploy-k3s.sh
NS=llm

[[ -f .env ]] || { echo "Missing .env — copy .env.example and set LLAMA_API_KEY"; exit 1; }

echo "==> Cluster prerequisites (GPU runtime + device plugin)"
$KUBECTL apply -f k8s/cluster/

echo "==> Namespace"
$KUBECTL apply -f k8s/00-namespace.yaml

echo "==> Config + secret (generated from files, applied idempotently)"
$KUBECTL -n "$NS" create configmap llm-config --from-env-file=config/model.env \
  --dry-run=client -o yaml | $KUBECTL apply -f -
$KUBECTL -n "$NS" create secret generic llm-secrets --from-env-file=.env \
  --dry-run=client -o yaml | $KUBECTL apply -f -

echo "==> App manifests"
$KUBECTL apply -f k8s/

echo "==> Restart so config changes are picked up"
$KUBECTL -n "$NS" rollout restart deployment/llm
$KUBECTL -n "$NS" rollout status deployment/llm --timeout=15m

echo "==> Done"
$KUBECTL -n "$NS" get pods,svc,hpa
