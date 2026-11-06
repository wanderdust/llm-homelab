# llm-homelab

A self-hosted coding-model API (llama.cpp `llama-server` + Qwen3.5-4B) on a single
GPU box, deployable two ways from the same config: Docker Compose or k3s.
Clients (e.g. the Pi coding agent) connect at `http://<server-ip>:8080/v1`.

## Layout

```
config/model.env              shared model/server settings (committed)
.env                          LLAMA_API_KEY (gitignored; copy from .env.example)
docker/compose.yaml           Docker deployment
k8s/00-namespace.yaml         ┐
k8s/10-pvc.yaml               │ app manifests, applied in filename order
k8s/20-deployment.yaml        │
k8s/30-service.yaml           │
k8s/40-hpa.yaml               ┘
k8s/cluster/                  one-time GPU setup for k3s (RuntimeClass + device plugin)
scripts/deploy-docker.sh      deploy with Docker
scripts/deploy-k3s.sh         deploy to k3s
```

## Docker ↔ k8s mapping

| Concern            | Docker Compose                     | k3s                                        |
|--------------------|------------------------------------|--------------------------------------------|
| Config             | `env_file: config/model.env`       | ConfigMap `llm-config` (same file)         |
| Secret             | `env_file: .env`                   | Secret `llm-secrets` (same file)           |
| GPU                | `deploy.resources...devices`       | `nvidia.com/gpu: 1` + `runtimeClassName`   |
| Model cache        | named volume `models`              | PVC `llm-models` (local-path)              |
| Health             | `healthcheck`                      | startup / readiness / liveness probes      |
| Expose port        | `ports: 8080:8080`                 | Service `type: LoadBalancer` (ServiceLB)   |
| Restart on failure | `restart: unless-stopped`          | Deployment controller + liveness probe     |
| Scaling            | —                                  | HPA (CPU, 1→2 replicas)                    |

## Prerequisites (on the server)

1. NVIDIA driver working: `nvidia-smi`
2. NVIDIA Container Toolkit installed (`nvidia-container-toolkit`)
3. Docker path: `sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker`
4. k3s path: install k3s **after** the toolkit (`curl -sfL https://get.k3s.io | sh -`),
   or `sudo systemctl restart k3s` after installing it, so k3s detects the NVIDIA runtime.
   Use `KUBECTL="sudo k3s kubectl"` or copy `/etc/rancher/k3s/k3s.yaml` to `~/.kube/config`.

## Deploy

```bash
cp .env.example .env && sed -i "s/change-me/$(openssl rand -hex 32)/" .env
./scripts/deploy-docker.sh    # or
./scripts/deploy-k3s.sh
```

Run one or the other: both bind port 8080 and both want the GPU.

Tear down: `docker compose -f docker/compose.yaml down` / `kubectl delete ns llm`.

## Test

```bash
curl http://<server-ip>:8080/v1/models -H "Authorization: Bearer $LLAMA_API_KEY"
```

## Notes

- **HPA on one GPU:** the 2nd replica stays `Pending`, because there's no free `nvidia.com/gpu`.
  That's the expected result here; on a node pool with more GPUs it would schedule.
- **Better scaling signal:** CPU is a weak proxy for LLM load. In production you'd
  scale on queue depth from `/metrics` (e.g. `llamacpp:requests_deferred`, or vLLM's
  `num_requests_waiting`) via Prometheus Adapter or KEDA.
- **Recreate strategy:** the Deployment uses `Recreate`, not rolling updates, because
  a single GPU can't hold the old and new pod at the same time.
- **Moving to vLLM:** swap the image and args. The API contract (`/v1`) and clients don't change.
