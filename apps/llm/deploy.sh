#!/usr/bin/env bash
# Deploy (or redeploy) the LLM app. Safe to run repeatedly.
# Requires cluster/setup.sh to have been run once (GPU label + device plugin).
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
KUBECTL="${KUBECTL:-kubectl}"
NS=llm

[[ -f .env ]] || { echo "Missing apps/llm/.env — copy .env.example and set LLAMA_API_KEY"; exit 1; }

echo "==> Namespace"
$KUBECTL apply -f k8s/00-namespace.yaml

echo "==> Config + secret (generated from files)"
$KUBECTL -n "$NS" create configmap llm-config --from-env-file=config/model.env \
  --dry-run=client -o yaml | $KUBECTL apply -f -
$KUBECTL -n "$NS" create secret generic llm-secrets --from-env-file=.env \
  --dry-run=client -o yaml | $KUBECTL apply -f -

echo "==> Manifests"
$KUBECTL apply -f k8s/

echo "==> Restart so config changes are picked up"
$KUBECTL -n "$NS" rollout restart deployment/llm
$KUBECTL -n "$NS" rollout status deployment/llm --timeout=15m

$KUBECTL -n "$NS" get pods,svc,hpa
