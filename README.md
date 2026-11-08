# homelab

All deployments for my k3s home lab, in one repo.
Cluster-wide setup lives in `cluster/`; each app lives in its own folder under `apps/`.

## Layout

```
cluster/
  setup.sh                    label GPU nodes, install NVIDIA runtime class + device plugin
  nvidia/                     runtimeclass.yaml, device-plugin.yaml
apps/
  llm/                        llama-server + Qwen3.5-4B, OpenAI-compatible API on :8080
    deploy.sh                 deploy / redeploy
    on.sh, off.sh             free the GPU (e.g. for training) and bring it back
    config/model.env          model + server settings (committed)
    .env                      LLAMA_API_KEY (gitignored; copy from .env.example)
    k8s/                      namespace, pvc, deployment, service, hpa
buildlog/                     notes and evidence for the write-up
```

## Usage

```bash
./cluster/setup.sh            # once, and again whenever nodes change
./apps/llm/deploy.sh          # deploy or redeploy the LLM
```

Aliases (`~/.bashrc`):

```bash
alias llm-on='~/repositories/homelab/apps/llm/on.sh'
alias llm-off='~/repositories/homelab/apps/llm/off.sh'
```

## Adding an app

Create `apps/<name>/` with a `k8s/` folder and a `deploy.sh`. Use its own namespace.
Non-GPU apps need no node rules (see below).

## Node placement

- GPU nodes carry the label `homelab/gpu=true` (set by `cluster/setup.sh`).
- GPU workloads (the LLM, the device plugin) use `nodeSelector: homelab/gpu: "true"`
  and already tolerate the `homelab/gpu` taint.
- To keep everything else off the GPU node, taint it **once there is a second,
  non-GPU node** (with one node it would block all other apps):

  ```bash
  kubectl taint node pablo-ubuntu homelab/gpu=true:NoSchedule
  ```

## Prerequisites (GPU node)

1. NVIDIA driver working: `nvidia-smi`
2. NVIDIA Container Toolkit installed (`nvidia-container-toolkit`)
3. k3s installed **after** the toolkit (or `sudo systemctl restart k3s`), so it
   detects the NVIDIA runtime.

## Notes

- The HPA (1→2 replicas on CPU) can't actually add capacity on one GPU: the 2nd pod
  stays `Pending`. A 3-minute scale-up window stops it reacting to the model-load spike.
- The Deployment uses `Recreate`, because one GPU can't hold the old and new pod at once.
- The first start downloads the image (~2.6 GB) and the model (~2.7 GB); later starts
  load from the PVC.
