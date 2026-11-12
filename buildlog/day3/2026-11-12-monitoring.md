# Monitoring — 2026-11-12

## What was added
`apps/monitoring/`: Prometheus (+ node-exporter, kube-state-metrics), an nvidia-smi GPU exporter
DaemonSet, Loki, Grafana Alloy and Grafana. Charts are installed through k3s `HelmChart` objects.
The spec is in `apps/monitoring/SPEC.md`.

| Component | Chart / image | Version |
|---|---|---|
| Prometheus | `prometheus-community/prometheus` | chart 29.47.2 (Prometheus v3.16.0) |
| Loki | `grafana-community/loki` | chart 21.2.1 (Loki 3.7.9) |
| Alloy | `grafana/alloy` | chart 1.15.0 (Alloy v1.21.3) |
| Grafana | `grafana-community/grafana` | chart 14.4.1 (Grafana 13.3.1) |
| GPU exporter | `utkuozdemir/nvidia_gpu_exporter` | 1.18.0 (nvidia-smi backend) |
| Dashboards | grafana.com 1860 / 14574 / 15757 / 15760 | revisions 46 / 18 / 43 / 41 |

## Why it's built this way
- **No Prometheus Operator (kube-prometheus-stack).** It was the first plan. On one node it costs
  more than it gives: CRDs, cross-namespace selector settings, ordering problems in deploy.sh and a
  manual CRD step on every upgrade. The plain Prometheus chart covers the need, and community
  dashboards replace its built-in ones.
- **The LLM scrape discovers pods, not the Service.** Service `llm` has no labels, and pod discovery
  needs no llm-app change. While `llm-off` is in effect, the job simply has no targets, instead of
  showing as down.
- **`/metrics` on llama-server needs the API key.** Only `/health` is public. The key is copied
  into `monitoring/llm-scrape` by deploy.sh and read by Prometheus from a file.
- **GPU exporter without `nvidia.com/gpu`.** The LLM holds the only GPU. The exporter uses the
  RuntimeClass `nvidia` plus `NVIDIA_VISIBLE_DEVICES=all`, so the runtime injects `nvidia-smi`. DCGM
  was not used because it doesn't officially support GeForce cards.
- **Alloy as a DaemonSet that reads `/var/log/pods`,** with read positions kept on the host
  (`/var/lib/alloy`). No logs are lost or duplicated across power-offs, and new nodes are covered
  automatically. Kubernetes events go to Loki too, with Alloy clustering so each event is shipped
  once when there are several nodes.
- **Loki caches disabled.** The chart's memcached chunk cache defaults to 8 GB of RAM.
- **Grafana without a volume.** Datasources and dashboards come from the repo.
- **Prometheus `retentionSize: 8GB`** in addition to 7d, because `local-path` doesn't enforce sizes.

## Outdated items found in the original spec
- Promtail is end-of-life (2026-03-02); Grafana Alloy replaces it.
- The Loki and Grafana Helm charts moved to `grafana-community/helm-charts`. The `grafana/loki`
  chart now targets Enterprise Logs, and `grafana/grafana` is deprecated.
- llama.cpp removed `llamacpp:kv_cache_usage_ratio` and `kv_cache_tokens`. The dashboard shows
  `llamacpp:n_tokens_max` (context high-water mark) instead.
- The chart's default `deploymentMode` for Loki is now named `Monolithic` (formerly `SingleBinary`).

## Still to check on the node (first deploy)
- `kube-dns` carries `prometheus.io/scrape`: is CoreDNS in the `kubernetes-service-endpoints` job?
- `grep accept-nvidia-visible-devices /etc/nvidia-container-runtime/config.toml` should be `true`
  or absent. If false, the GPU exporter sees no GPU.
- Metric names on the running llama.cpp build:
  `curl -s -H "Authorization: Bearer $KEY" http://<node>:8080/metrics`. The image tag
  `server-cuda` is unpinned, so names can change.
