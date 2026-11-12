#!/usr/bin/env bash
# Free the GPU: scale the model server to 0, wait until the GPU is released.
# The "off" state survives reboots (replicas=0 is stored in the cluster).
set -euo pipefail

KUBECTL="${KUBECTL:-kubectl}"
NS=llm

echo "==> Scaling model server to 0"
$KUBECTL -n "$NS" scale deployment llm --replicas=0

echo "==> Waiting for the pod to exit"
$KUBECTL -n "$NS" wait --for=delete pod -l app=llm --timeout=120s 2>/dev/null || true

echo "==> GPU memory now in use:"
nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader
echo "GPU is free. Bring the model back with: llm-on"
