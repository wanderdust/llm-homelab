#!/usr/bin/env bash
# Cluster-wide setup: label GPU nodes, install the NVIDIA runtime class + device plugin.
# Safe to run repeatedly. Run again whenever you add a node.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
KUBECTL="${KUBECTL:-kubectl}"

# Space-separated list of nodes that have an NVIDIA GPU.
#   GPU_NODES="node-a node-b" ./cluster/setup.sh
GPU_NODES="${GPU_NODES:-pablo-ubuntu}"

echo "==> Labelling GPU nodes: $GPU_NODES"
for n in $GPU_NODES; do
  $KUBECTL label node "$n" homelab/gpu=true --overwrite
done

echo "==> NVIDIA runtime class + device plugin"
$KUBECTL apply -f nvidia/

echo "==> Nodes"
$KUBECTL get nodes -L homelab/gpu
