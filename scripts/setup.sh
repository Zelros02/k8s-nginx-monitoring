#!/usr/bin/env bash
# Idempotent ramp-up script for the nginx monitoring stack.
#
#
# Prereqs: docker, kubectl, kind, helm. The script refuses to continue if any
# of them is missing.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFESTS="${ROOT}/manifests"
KIND_CONFIG="${ROOT}/kind-config.yaml"

log() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }

for bin in docker kubectl kind helm; do
  command -v "$bin" >/dev/null || { echo "Missing: $bin" >&2; exit 1; }
done

# ------------------------------------------------------------------ cluster
log "Kind cluster"
if ! kind get clusters | grep -qx nginx-monitoring; then
  kind create cluster --config "${KIND_CONFIG}"
else
  echo "Cluster 'nginx-monitoring' already exists, skipping create."
fi
kubectl cluster-info --context kind-nginx-monitoring

log "nginx deployment + service"
kubectl apply -f "${MANIFESTS}/01-nginx-configmap.yaml"
kubectl apply -f "${MANIFESTS}/02-nginx-html-configmap.yaml"
kubectl apply -f "${MANIFESTS}/03-nginx-deployment.yaml"
kubectl apply -f "${MANIFESTS}/04-nginx-service.yaml"
kubectl -n default rollout status deploy/nginx --timeout=120s

# ------------------------------------------------------------------ exporter
log "nginx-prometheus-exporter"
kubectl apply -f "${MANIFESTS}/05-exporter-deployment.yaml"
kubectl apply -f "${MANIFESTS}/06-exporter-service.yaml"
kubectl -n default rollout status deploy/nginx-prometheus-exporter --timeout=120s

# ------------------------------------------------------------------ prometheus
log "monitoring namespace + Prometheus via Helm"
kubectl apply -f "${MANIFESTS}/00-namespace-monitoring.yaml"

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add grafana               https://grafana.github.io/helm-charts            >/dev/null 2>&1 || true
helm repo update

helm upgrade --install prometheus prometheus-community/prometheus \
  -n monitoring \
  -f "${MANIFESTS}/07-prometheus-values.yaml"

kubectl -n monitoring rollout status deploy/prometheus-server --timeout=180s

# ------------------------------------------------------------------ grafana
log "Grafana via Helm"
helm upgrade --install grafana grafana/grafana \
  -n monitoring \
  -f "${MANIFESTS}/08-grafana-values.yaml"

kubectl -n monitoring rollout status deploy/grafana --timeout=180s

log "Done. See README.md for port-forward and verification commands."
