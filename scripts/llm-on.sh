#!/usr/bin/env bash
# Bring the model server back: scale to 1, wait until ready, then restore the HPA.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."

KUBECTL="${KUBECTL:-kubectl}"
NS=llm

if nvidia-smi --query-compute-apps=pid --format=csv,noheader | grep -q .; then
  echo "Warning: something is still using the GPU (training still running?):"
  nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader
  read -rp "Start the model anyway? [y/N] " ans
  [[ "$ans" == [yY] ]] || exit 1
fi

echo "==> Scaling model server to 1"
$KUBECTL -n "$NS" scale deployment llm --replicas=1

echo "==> Waiting for the model to load"
$KUBECTL -n "$NS" rollout status deployment/llm --timeout=10m

# Restore the HPA *after* scaling up: an HPA won't scale a Deployment up from 0.
echo "==> Restoring HPA"
$KUBECTL apply -f k8s/40-hpa.yaml

echo "Model server is up."
