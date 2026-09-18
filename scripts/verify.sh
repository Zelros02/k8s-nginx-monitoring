#!/usr/bin/env bash
# Verification script — run after setup.sh has finished and Helm releases are ready.
# Exits non-zero on the first failed check.

set -euo pipefail

pass() { printf '  \033[1;32m[OK]\033[0m  %s\n' "$*"; }
fail() { printf '  \033[1;31m[FAIL]\033[0m %s\n' "$*"; exit 1; }
hdr()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- Cluster
hdr "Kubernetes cluster"
kubectl get nodes -o wide
kubectl cluster-info >/dev/null && pass "API server reachable"

# ---------------------------------------------------------------- nginx
hdr "nginx deployment + service"
kubectl -n default get deploy nginx >/dev/null && pass "Deployment nginx exists"
kubectl -n default get svc nginx -o jsonpath='{.spec.ports[*].nodePort}' | grep -q 30080 \
  && pass "Service nginx exposes nodePort 30080"
kubectl -n default get svc nginx -o jsonpath='{.spec.ports[*].nodePort}' | grep -q 30088 \
  && pass "Service nginx exposes nodePort 30088"

# In-cluster checks via a throwaway pod
kubectl run curl-check --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
  sh -c 'curl -fsS http://nginx/ >/dev/null && curl -fsS http://nginx:8080/metrics | head -n3' \
  && pass "nginx serves on :80 AND /metrics on :8080"

# Host port-mapped check (only works on the same machine that runs the kind container)
curl -fsS "http://localhost:30080/" >/dev/null && pass "host :30080 → nginx"
curl -fsS "http://localhost:30088/metrics" | grep -q "Active connections" && pass "host :30088 → stub_status"

# ---------------------------------------------------------------- exporter
hdr "nginx-prometheus-exporter"
kubectl -n default get deploy nginx-prometheus-exporter >/dev/null && pass "Deployment exists"
kubectl -n default get svc promexporter -o jsonpath='{.spec.ports[0].port}' | grep -qx 9113 \
  && pass "Service promexporter on port 9113"

kubectl run curl-check2 --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
  sh -c 'curl -fsS http://promexporter.default.svc.cluster.local:9113/metrics | grep -q nginx_connections_accepted' \
  && pass "exporter exposes nginx_connections_accepted in Prometheus format"

# ---------------------------------------------------------------- prometheus
hdr "Prometheus"
kubectl -n monitoring get deploy prometheus-server >/dev/null && pass "prometheus-server deployed in monitoring ns"
helm -n monitoring status prometheus >/dev/null && pass "Helm release 'prometheus' present"

# Scrape config picked up our extraScrapeConfigs job
kubectl -n monitoring get cm prometheus-server -o jsonpath='{.data.prometheus\.yml}' \
  | grep -q "promexporter.default.svc.cluster.local:9113" \
  && pass "prometheus.yml references promexporter target"

echo "  Verify in Prometheus UI:"
echo "    kubectl -n monitoring port-forward svc/prometheus-server 9090:80"
echo "    open http://localhost:9090/targets  → 'nginx' job should be UP"
echo "    query: nginx_connections_accepted"

# ---------------------------------------------------------------- grafana
hdr "Grafana"
kubectl -n monitoring get deploy grafana >/dev/null && pass "grafana deployed in monitoring ns"
helm -n monitoring status grafana >/dev/null && pass "Helm release 'grafana' present"

ADMIN_PASS=$(kubectl -n monitoring get secret grafana -o jsonpath='{.data.admin-password}' | base64 -d)
[ -n "$ADMIN_PASS" ] && pass "Grafana admin password retrievable (length=${#ADMIN_PASS})"

echo "  Verify in Grafana UI:"
echo "    kubectl -n monitoring port-forward svc/grafana 3000:80"
echo "    open http://localhost:3000  (user: admin, pass: $ADMIN_PASS)"
echo "    Configuration → Data Sources → Prometheus should be green"
echo "    Dashboards → NGINX Prometheus Exporter (provisioned from gnetId 12708)"

# ---------------------------------------------------------------- dos
hdr "Slowloris load test"
command -v slowhttptest >/dev/null && pass "slowhttptest installed" \
  || echo "  (install with your package manager, e.g. apt install slowhttptest / pacman -S slowhttptest)"
echo "  Open the Grafana dashboard, then run scripts/dos-test.sh and watch"
echo "  active/reading connections saturate and recover (see docs/dos-and-hardening.md)."

hdr "All automated checks passed."
