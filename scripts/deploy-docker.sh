#!/usr/bin/env bash
# Deploy (or redeploy) the LLM server with Docker Compose. Safe to run repeatedly.
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -f .env ]] || { echo "Missing .env — copy .env.example and set LLAMA_API_KEY"; exit 1; }

docker compose -f docker/compose.yaml pull
docker compose -f docker/compose.yaml up -d --force-recreate
docker compose -f docker/compose.yaml ps
echo "Follow logs: docker compose -f docker/compose.yaml logs -f"
