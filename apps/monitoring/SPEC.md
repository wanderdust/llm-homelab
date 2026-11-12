# Spec: monitoring for the homelab cluster (v3, simplified, 2026-11-12)

## Purpose

Add a monitoring app to the `homelab` repo that gives:

1. **Metrics**: node, pod and Kubernetes object metrics, plus LLM-server metrics, stored over time.
2. **GPU metrics**: memory, utilisation, temperature, SM clock and power.
3. **Logs**: container logs and Kubernetes events from every namespace, stored, searchable and exportable.
4. **Dashboards**: one Grafana for all of the above.

Keep it small. This is a one-node home lab, so use the fewest moving parts that still follow good practice:
config-as-code, pinned versions, no secrets in git, idempotent deploys, a check at every step.

## Stack

| Component | How it's installed | Role |
|---|---|---|
| Prometheus | k3s `HelmChart`: `prometheus-community/prometheus` | Metrics storage and scraping. It bundles node-exporter and kube-state-metrics. **No operator and no CRDs.** |
| GPU exporter | Plain DaemonSet manifest | nvidia-smi based exporter (e.g. `utkuozdemir/nvidia_gpu_exporter`). Scraped through pod annotations. |
| Loki | k3s `HelmChart`: Loki chart from `grafana-community/helm-charts` | Log storage, single binary. |
| Grafana Alloy | k3s `HelmChart`: Alloy chart | Log collector DaemonSet. Also ships Kubernetes events. |
| Grafana | k3s `HelmChart`: Grafana chart (check the repo: probably `grafana-community`) | Dashboards and log search. Datasources and dashboards are provisioned from the repo. |

## Decisions and outdated items

Copy these into the buildlog note.

- **Prometheus Operator / kube-prometheus-stack is not used.** It is too heavy for this lab: it brings CRDs,
  cross-namespace selector settings, a CRD-ordering problem in `deploy.sh` and a manual CRD step on every upgrade.
  The plain Prometheus chart drops all of that. The cost is no ready-made Kubernetes dashboards or recording rules;
  community dashboards replace them.
- **Promtail is EOL (2026-03-02)** and so is Grafana Agent. Use **Grafana Alloy**.
- **The Loki chart moved to `grafana-community/helm-charts` (2026-03-16).** The Grafana chart is moving the same
  way. Check each chart's current repo before pinning.
- **llama.cpp removed `llamacpp:kv_cache_usage_ratio` and `kv_cache_tokens`** in recent builds. Build panels from
  the real `/metrics` output.
- **`/metrics` on llama-server requires the API key** (Bearer token).
- **Loki's chart defaults deploy memcached caches.** The chunk cache requests about 8 GB RAM, so they must be
  disabled.
- **`local-path` volumes are tied to the node they were created on.** Prometheus and Loki stay on `pablo-ubuntu`
  until their PVCs are deleted. That is the migration path when a non-GPU node arrives, and losing ≤7 days of data
  is acceptable.
- **Collector mode:** an Alloy DaemonSet reads `/var/log/pods` on each node. Its positions file means no lost or
  duplicate logs across restarts and power-offs, and new nodes are covered automatically.
- **Exposure:** only Grafana is reachable on the LAN. Prometheus and Loki have no auth, so use port-forward.

---

## Environment (current state)

- **Cluster**: k3s, single node `pablo-ubuntu`, SQLite datastore. Later nodes may include a small always-on
  non-GPU node.
- **Node**: Ryzen 5 3600, 15 GB RAM, RTX 2060 6 GB (GeForce), NVMe. It is often powered off, and gaps are fine.
- **k3s built-ins**: Helm controller (`HelmChart`), ServiceLB, `local-path`, metrics-server.
- **GPU setup** (`cluster/`): label `homelab/gpu=true`, RuntimeClass `nvidia`, device plugin. A taint
  `homelab/gpu=true:NoSchedule` is planned for later.
- **LLM app**: namespace `llm`, pods labelled `app=llm`, container port named `http` (8080), `/metrics` enabled and
  protected by `LLAMA_API_KEY` (from `apps/llm/.env`). `llm-off` scales it to 0. The GPU is fully claimed by this
  pod.

## Repo layout

```
apps/monitoring/
  deploy.sh
  .env.example                  GRAFANA_ADMIN_USER, GRAFANA_ADMIN_PASSWORD
  k8s/
    00-namespace.yaml           namespace monitoring
    10-prometheus.yaml          HelmChart (pinned version + valuesContent)
    20-gpu-exporter.yaml        DaemonSet
    30-loki.yaml                HelmChart
    40-alloy.yaml               HelmChart
    50-grafana.yaml             HelmChart
  dashboards/
    llm-gpu.json                custom dashboard (the only dashboard JSON kept in the repo)
```

Conventions: no Helm CLI. HelmChart objects live in `kube-system` with `targetNamespace: monitoring`. Chart, version
and values are all in the YAML. Respect `KUBECTL`.

## deploy.sh

1. Fail if `apps/monitoring/.env` is missing.
2. Apply `00-namespace.yaml`.
3. Generate the Secrets with `create --dry-run=client -o yaml | apply`:
   - `grafana-admin` from `apps/monitoring/.env`.
   - `llm-scrape` (key `LLAMA_API_KEY`) from `apps/llm/.env`. Warn and skip if that file is missing; the LLM
     target will then fail to scrape. The key now exists in two Secrets but still never in git.
     **If the key is rotated, re-run both deploy scripts.**
4. Generate ConfigMap `grafana-dashboards` from `dashboards/`, the same way.
5. `kubectl apply -f k8s/`.
6. Wait for each workload to exist and become ready: Prometheus server, kube-state-metrics, node-exporter, GPU
   exporter, Loki, Alloy, Grafana. Use a wait loop, because the Helm install jobs create them asynchronously.
7. Print pods and services, plus the Grafana URL.

No `rollout restart`. Re-running with no changes must not restart any pod. Helm-controller upgrades a release
only when its `valuesContent` or `version` changes.

---

## Requirements

### 1. Prometheus (`prometheus-community/prometheus`)
- Disable `alertmanager` and `prometheus-pushgateway`. Enable the `kube-state-metrics` and
  `prometheus-node-exporter` subcharts.
- `server.retention: 7d`, `server.retentionSize: 8GB`, PVC 10Gi on `local-path`.
- **`server.strategy: Recreate`.** Prometheus uses a single-writer PVC, and a rolling update would start a second
  server against a locked database.
- Requests/limits roughly 200m / 512Mi request, 1Gi limit.
- Service `ClusterIP` only.
- node-exporter tolerates all taints, so it runs on every node.
- Keep the chart's default jobs: apiserver, kubelet/cAdvisor via the apiserver proxy, annotated pods, annotated
  service endpoints, and Prometheus itself. Annotated endpoints include CoreDNS, if k3s's `kube-dns` service
  carries the `prometheus.io/scrape` annotation; verify. The chart has no etcd, scheduler or controller-manager
  jobs, so nothing shows as permanently down on k3s.
- **LLM scrape**, as one `llm` entry in the chart's `scrapeConfigs` map:
  - `kubernetes_sd_configs` role `pod`, namespace `llm`.
  - Keep `app=llm` and container port name `http`. Path `/metrics`, interval 15s.
  - `authorization: { type: Bearer, credentials_file: /etc/llm-scrape/LLAMA_API_KEY }`.
  - Secret `llm-scrape` is mounted through `server.extraSecretMounts`. Prometheus re-reads the file on each
    scrape, so rotating the key needs no restart.
  - No change to the llm app. While `llm-off`, the target simply has no endpoints.

### 2. GPU exporter (plain DaemonSet)
- An nvidia-smi based exporter, image pinned. Check that the project is still maintained and note the version.
- `runtimeClassName: nvidia`, `NVIDIA_VISIBLE_DEVICES=all`, `NVIDIA_DRIVER_CAPABILITIES=utility`. The runtime
  injects `nvidia-smi`.
- **No `nvidia.com/gpu` request.** This relies on the NVIDIA toolkit setting
  `accept-nvidia-visible-devices-envvar-when-unprivileged` (default `true`); verify it on the node.
- `nodeSelector homelab/gpu: "true"`. Tolerate `homelab/gpu` and `nvidia.com/gpu`.
- Requests 10m/32Mi, limit 64Mi. `readOnlyRootFilesystem`, drop all capabilities, non-root if the image allows it.
- Pod annotations: `prometheus.io/scrape: "true"`, `prometheus.io/port: "<exporter port>"`.
- Metrics needed: memory used/total, utilisation, temperature, SM clock, power draw. Check the exact names against
  the exporter's output.

### 3. Loki (community chart)
- `deploymentMode: Monolithic` (the chart's new name for SingleBinary), filesystem storage, PVC 10Gi `local-path`, `auth_enabled: false`, schema
  v13/tsdb.
- Retention: compactor `retention_enabled: true`, `delete_request_store: filesystem`,
  `limits_config.retention_period: 168h`.
- Disable `chunksCache`, `resultsCache`, `lokiCanary`, `test` and `gateway`. Set read/write/backend replicas to 0.
- Requests roughly 100m/256Mi, limit 512Mi. Service `ClusterIP`.

### 4. Alloy (DaemonSet)
- Pipeline:
  - `discovery.kubernetes` (pods on its own node)
  - `discovery.relabel`, producing labels `namespace`, `pod`, `container`, `app`, `node`
  - `loki.source.file` on `/var/log/pods/*/*/*.log`, mounted read-only
  - `loki.process` with the CRI stage
  - `loki.write` to Loki
- `loki.source.kubernetes_events` → Loki. Turn on Alloy clustering so only one instance collects events once
  there are several nodes.
- Tolerate all taints. Requests roughly 50m/128Mi, limit 256Mi.

### 5. Grafana (chart)
- `admin.existingSecret: grafana-admin`. Service `LoadBalancer` port 3000, so the URL is
  `http://<node-ip>:3000`.
- **No persistence.** Everything is provisioned, so a restart loses nothing defined in the repo. Dashboards edited
  in the UI must be exported to the repo to survive.
- Datasources (provisioned): Prometheus (default) at the in-cluster server service, and Loki.
- Dashboards (provisioned):
  - Community dashboards pulled by `gnetId` with a **pinned `revision`**: Node Exporter Full, an
    nvidia_gpu_exporter dashboard, and one Kubernetes pods/namespaces view.
  - Custom `llm-gpu` dashboard from ConfigMap `grafana-dashboards`.
  - Note: `gnetId` dashboards are downloaded when the pod starts, so they need internet access.
- Requests roughly 50m/256Mi, limit 512Mi (Grafana 13 is OOMKilled at 256Mi on startup).

### 6. Custom LLM + GPU dashboard (`dashboards/llm-gpu.json`)
- Panels:
  - prompt and generation tokens/sec (`llamacpp:prompt_tokens_seconds`, `llamacpp:predicted_tokens_seconds`)
  - requests processing and **deferred/queued** (`llamacpp:requests_processing`,
    `llamacpp:requests_deferred`)
  - token rates from `*_total` counters
  - KV-cache usage, only if exposed
  - GPU memory, utilisation, temperature, SM clock, power
  - LLM pod restarts (`kube_pod_container_status_restarts_total{namespace="llm"}`)
  - logs panel `{namespace="llm"}`
- Confirm every metric name against the live `/metrics` output first. The llm image is the unpinned
  `server-cuda` tag. Pinning it is recommended; that is a flagged, optional llm change.

### 7. Exporting logs
Document three ways:
- Grafana Explore → Inspect → Data → download.
- `logcli` against `kubectl -n monitoring port-forward svc/loki 3100`.
- The HTTP API `/loki/api/v1/query_range`. Page large ranges by time, because of the per-query line limit
  (5000 by default).

---

## Phases

Stop after each phase and report what to check.

1. Prometheus (+ node-exporter, kube-state-metrics, LLM scrape) and Grafana with the Prometheus datasource.
2. GPU exporter.
3. Loki, Alloy and the Loki datasource.
4. Custom dashboard, community dashboards, README and buildlog note.

## Non-goals

Alerting, tracing, HA, ingress/TLS, remote backends, Prometheus Operator. No llm-app changes are required.
Pinning the llm image is optional and flagged.

## Constraints

- RAM ≤ ~1.5 GB total, with explicit requests and limits everywhere:
  - Prometheus ~512Mi–1Gi
  - Loki ~256–512Mi
  - Alloy ~128–256Mi
  - Grafana ~256–512Mi
  - node-exporter and kube-state-metrics ~100Mi together
  - GPU exporter ~32Mi
- No GPU requests.
- Comes back by itself after power-off and power-on.
- Works when a non-GPU node is added. Only the GPU exporter is GPU-bound; stateful pods move only by recreating
  their PVCs.
- All charts and images pinned. No secrets in git.

## Verification / acceptance

- **Every phase:** `kubectl -n kube-system get jobs | grep helm-install` shows the jobs completed, the job logs
  have no errors, and the pods in `monitoring` are Ready. A successful `kubectl apply` alone is not success.
- **Phase 1:**
  - Grafana opens at `http://<node-ip>:3000` with the admin credentials from `.env`.
  - The Prometheus targets page (`port-forward svc/<prometheus-server> 9090`) shows the apiserver, kubelet,
    cAdvisor, node-exporter, kube-state-metrics and `llm` jobs UP (`llm` only while the LLM is on).
  - `llamacpp:*` series are queryable in Grafana.
- **Phase 2:**
  - The DaemonSet shows 1/1 on `pablo-ubuntu`, and the GPU metrics are queryable.
  - The LLM pod is still 1/1 with `nvidia.com/gpu: 1` and no new restarts.
- **Phase 3:**
  - `{namespace="llm", container="llama-server"}` returns server output.
  - After `kubectl -n llm delete pod -l app=llm`, the old pod's logs are still queryable.
  - Kubernetes events are visible.
- **Phase 4:** after a fresh deploy, all dashboards load with no manual clicks.
- **Idempotency:** a second `deploy.sh` run restarts no pods (compare pod ages).
- **Power cycle:** after a node reboot, all monitoring pods return Ready by themselves.

## Upgrades and removal (for the README)

- To upgrade a component, bump `version:` in its HelmChart and re-run `deploy.sh`. There are no CRDs to manage.
- Removing a file from `k8s/` does **not** uninstall anything. Run `kubectl delete -f <file>`; for a HelmChart that
  uninstalls the release.
- To move Prometheus or Loki to another node, delete their PVCs and redeploy. Their data is lost.

## Deliverables

- `apps/monitoring/` (deploy script, manifests, `.env.example`, custom dashboard).
- README updates: layout, deploy, Grafana access, log export, upgrades and removal, the PVC note.
- `buildlog/` note: the stack chosen and the outdated items listed above.
