#!/usr/bin/env bash
# Deploy (or redeploy) the Excalidraw canvas. Safe to run repeatedly: nothing is restarted
# unless a manifest changed.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
KUBECTL="${KUBECTL:-kubectl}"
NS=excalidraw

$KUBECTL apply -f k8s/
$KUBECTL -n "$NS" rollout status deployment/canvas --timeout=5m
$KUBECTL -n "$NS" get pods,svc
echo
echo "Canvas: http://<node-ip>:3001"
