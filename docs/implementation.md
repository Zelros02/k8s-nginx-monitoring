# Implementation notes

How the stack is built, component by component. Commands assume you are in the
repo root; `scripts/setup.sh` runs all of them in order and is idempotent.

## Repository layout

```
.
├── kind-config.yaml                    Kind cluster + host port mappings
├── manifests/
│   ├── 00-namespace-monitoring.yaml    'monitoring' namespace
│   ├── 01-nginx-configmap.yaml         nginx.conf, two server blocks (80, 8080)
│   ├── 02-nginx-html-configmap.yaml    index.html served on :80
│   ├── 03-nginx-deployment.yaml        nginx pod template + probes
│   ├── 04-nginx-service.yaml           Service 'nginx' NodePort 30080/30088
│   ├── 05-exporter-deployment.yaml     nginx-prometheus-exporter
│   ├── 06-exporter-service.yaml        Service 'promexporter' :9113
│   ├── 07-prometheus-values.yaml       Helm values for the Prometheus chart
│   └── 08-grafana-values.yaml          Helm values for the Grafana chart
├── scripts/
│   ├── setup.sh                        One-shot bring-up (idempotent)
│   ├── verify.sh                       Automated post-setup checks
│   └── dos-test.sh                     slowhttptest driver
└── docs/
    ├── implementation.md               THIS FILE
    ├── verification.md                 How to verify each component
    └── dos-and-hardening.md            Slowloris observation + hardening proposal
```

## nginx with a separate metrics port

- **`kind-config.yaml`** — a single-node cluster with `extraPortMappings` for
  `30080` (the HTML site) and `30088` (metrics), so both NodePorts are reachable
  from the host.
- **`manifests/01-nginx-configmap.yaml`** — an `nginx.conf` with **two** `server`
  blocks: `listen 80` serves `index.html`, and `listen 8080` exposes `/metrics`
  through the `stub_status` module (everything else on 8080 returns 404). Keeping
  metrics on a separate port means the public site never exposes connection
  counts.
- **`manifests/02-nginx-html-configmap.yaml`** — the `index.html` payload.
- **`manifests/03-nginx-deployment.yaml`** — one replica of `nginx:1.27-alpine`,
  mounting both ConfigMaps, declaring container ports `80` and `8080`, with a
  readiness probe on `:80/` and a liveness probe on `:8080/metrics`.
- **`manifests/04-nginx-service.yaml`** — Service `nginx`, `type: NodePort`,
  `80 → 30080` and `8080 → 30088`.

```bash
kind create cluster --config kind-config.yaml
kubectl apply -f manifests/01-nginx-configmap.yaml
kubectl apply -f manifests/02-nginx-html-configmap.yaml
kubectl apply -f manifests/03-nginx-deployment.yaml
kubectl apply -f manifests/04-nginx-service.yaml
kubectl -n default rollout status deploy/nginx --timeout=120s
```

The stub_status endpoint looks like this:

```text
$ curl -s http://localhost:30088/metrics
Active connections: 1
server accepts handled requests
 25 25 25
Reading: 0 Writing: 1 Waiting: 0
```

## nginx-prometheus-exporter

`stub_status` is not Prometheus format, so the exporter translates it.

- **`manifests/05-exporter-deployment.yaml`** — `nginx/nginx-prometheus-exporter:1.3.0`
  with `-nginx.scrape-uri=http://nginx:8080/metrics` (the `nginx` Service from the
  previous step resolves in-cluster).
- **`manifests/06-exporter-service.yaml`** — Service `promexporter`,
  `ClusterIP`, port `9113`.

```bash
kubectl apply -f manifests/05-exporter-deployment.yaml
kubectl apply -f manifests/06-exporter-service.yaml
kubectl -n default rollout status deploy/nginx-prometheus-exporter --timeout=120s
```

```text
$ curl -s http://promexporter.default.svc.cluster.local:9113/metrics | head
# HELP nginx_connections_accepted Accepted client connections
# TYPE nginx_connections_accepted counter
nginx_connections_accepted 27
# HELP nginx_connections_active Active client connections
# TYPE nginx_connections_active gauge
nginx_connections_active 1
```

## Prometheus (Helm)

- **`manifests/00-namespace-monitoring.yaml`** — the `monitoring` namespace.
- **`manifests/07-prometheus-values.yaml`** — Helm values that disable
  Alertmanager, pushgateway, and the persistent volume (Kind has no default
  storage class), and add an `extraScrapeConfigs` job named `nginx` pointing at
  `promexporter.default.svc.cluster.local:9113`. The FQDN is required because
  Prometheus lives in a different namespace from the exporter.

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana               https://grafana.github.io/helm-charts
helm repo update

kubectl apply -f manifests/00-namespace-monitoring.yaml
helm upgrade --install prometheus prometheus-community/prometheus \
  -n monitoring -f manifests/07-prometheus-values.yaml
kubectl -n monitoring rollout status deploy/prometheus-server --timeout=180s
```

Result: the `nginx` job shows **UP** on `/targets`, and querying
`nginx_connections_accepted` returns a series that climbs as you curl the site.

## Grafana (Helm)

- **`manifests/08-grafana-values.yaml`** — Helm values that **declaratively**
  provision the Prometheus datasource (`http://prometheus-server`, no namespace
  suffix since both live in `monitoring`), the dashboard provider, and the
  official **NGINX Prometheus Exporter** dashboard from Grafana.com
  ([gnetId 12708](https://grafana.com/grafana/dashboards/12708)). No manual
  import step.

```bash
helm upgrade --install grafana grafana/grafana \
  -n monitoring -f manifests/08-grafana-values.yaml
kubectl -n monitoring rollout status deploy/grafana --timeout=180s

# The chart generates a random admin password into a Secret:
kubectl -n monitoring get secret grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d ; echo
```

Log in as `admin` with that password; the datasource shows green and the NGINX
dashboard renders live panels that move when you curl `http://localhost:30080/`.

## One-shot reproduction

```bash
bash scripts/setup.sh    # creates the cluster and deploys everything
bash scripts/verify.sh   # automated post-setup checks
bash scripts/dos-test.sh # slowloris load test (interactive)
```
