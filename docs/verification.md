# Verification

> Run each block after `scripts/setup.sh` has finished. Every check prints what a
> **correct** result looks like; all commands are idempotent and non-destructive.
>
> Tip: `bash scripts/verify.sh` runs the nginx / exporter / Prometheus / Grafana
> checks automatically (exit code 0 = pass).


## nginx cluster + service

```bash
# 1. Cluster exists and is healthy
kind get clusters | grep -x nginx-monitoring
kubectl cluster-info --context kind-nginx-monitoring
kubectl get nodes
# Expected: one node, STATUS=Ready

# 2. Deployment is rolled out
kubectl -n default get deploy nginx -o wide
# Expected: READY 1/1

# 3. Both Service ports exist and the NodePorts are as configured
kubectl -n default get svc nginx -o yaml | grep -E 'nodePort|port:|name:'
# Expected: port 80 -> nodePort 30080, port 8080 -> nodePort 30088

# 4. In-cluster: HTML page on :80 works
kubectl run probe1 --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
  curl -fsS http://nginx/ | head
# Expected: <!doctype html> ... nginx ... 

# 5. In-cluster: stub_status on :8080 works
kubectl run probe2 --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
  curl -fsS http://nginx:8080/metrics
# Expected:
#   Active connections: <n>
#   server accepts handled requests
#   ...

# 6. From the VM (NodePort, host network)
curl -fsS http://localhost:30080/ | head
curl -fsS http://localhost:30088/metrics

# 7. CRITICAL CHECK: metrics must NOT be reachable on port 80
! curl -fsS http://localhost:30080/metrics 2>/dev/null
echo "expected: command fails with 404 (good - metrics are isolated to :8080)"
```

---

## nginx-prometheus-exporter

```bash
# 1. Deployment + Service exist
kubectl -n default get deploy nginx-prometheus-exporter
kubectl -n default get svc promexporter

# 2. The Service uses port 9113 
kubectl -n default get svc promexporter -o jsonpath='{.spec.ports[0].port}{"\n"}'
# Expected: 9113

# 3. Container has the correct --nginx.scrape-uri arg
kubectl -n default get deploy nginx-prometheus-exporter \
  -o jsonpath='{.spec.template.spec.containers[0].args}'
# Expected: ["-nginx.scrape-uri=http://nginx:8080/metrics"]

# 4. Exporter is actually serving Prometheus-formatted metrics
kubectl run probe3 --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
  curl -fsS http://promexporter.default.svc.cluster.local:9113/metrics | \
  grep -E '^nginx_(connections_accepted|up)' | head
# Expected:
#   nginx_connections_accepted ...
#   nginx_up 1
```

---

## Prometheus

```bash
# 1. Helm release present in the right namespace
helm -n monitoring list | grep prometheus
helm -n monitoring status prometheus | head

# 2. Pod is running
kubectl -n monitoring get pods -l app.kubernetes.io/name=prometheus

# 3. Scrape config was loaded with the FQDN target
kubectl -n monitoring get cm prometheus-server \
  -o jsonpath='{.data.prometheus\.yml}' \
  | grep -A2 'job_name: .nginx.'
# Expected: targets includes 'promexporter.default.svc.cluster.local:9113'

# 4. Targets API confirms it's UP (do this AFTER port-forward)
kubectl -n monitoring port-forward svc/prometheus-server 9090:80 &
sleep 3
curl -s http://localhost:9090/api/v1/targets \
  | grep -o '"job":"nginx"[^}]*"health":"[^"]*"'
# Expected: "job":"nginx" ... "health":"up"

# 5. A real query returns data
curl -sG http://localhost:9090/api/v1/query \
  --data-urlencode 'query=nginx_connections_accepted' \
  | grep -o '"resultType":"vector","result":\[[^]]'
# Expected: a non-empty result vector

# 6. Generate traffic and confirm the metric increases
for i in $(seq 1 50); do curl -s http://localhost:30080/ >/dev/null; done
sleep 15
curl -sG http://localhost:9090/api/v1/query \
  --data-urlencode 'query=rate(nginx_connections_accepted[1m])'
# Expected: a positive rate
```

---

## Grafana

```bash
# 1. Helm release + pod
helm -n monitoring list | grep grafana
kubectl -n monitoring get deploy grafana

# 2. Admin password retrievable
kubectl -n monitoring get secret grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d ; echo

# 3. Port-forward and check the API
kubectl -n monitoring port-forward svc/grafana 3000:80 &
sleep 3
PASS=$(kubectl -n monitoring get secret grafana -o jsonpath='{.data.admin-password}' | base64 -d)

# 4. Datasource is provisioned and pointing at the right URL
curl -s -u admin:"$PASS" http://localhost:3000/api/datasources | \
  python3 -c 'import sys,json; ds=json.load(sys.stdin); print(ds[0]["name"], ds[0]["type"], ds[0]["url"])'
# Expected: Prometheus prometheus http://prometheus-server

# 5. Datasource health check passes
DS_ID=$(curl -s -u admin:"$PASS" http://localhost:3000/api/datasources/name/Prometheus | \
  python3 -c 'import sys,json; print(json.load(sys.stdin)["uid"])')
curl -s -u admin:"$PASS" "http://localhost:3000/api/datasources/uid/${DS_ID}/health"
# Expected: {"status":"OK", ...}

# 6. The nginx dashboard is provisioned
curl -s -u admin:"$PASS" "http://localhost:3000/api/search?type=dash-db" | \
  python3 -m json.tool | grep -i nginx
# Expected: a match for the nginx-prometheus-exporter dashboard
```

Open the UI in the browser:
- `http://localhost:3000` → log in with `admin` / value from step 2.
- Dashboards → **NGINX Prometheus Exporter** → panels show live data when you
  `curl http://localhost:30080/` repeatedly.

---

## Slowloris load test

```bash
# 1. Tool installed
slowhttptest -v
# Expected: a version banner

# 2. Pre-run sanity (Grafana shows baseline)
for i in $(seq 1 20); do curl -s http://localhost:30080/ >/dev/null; done

# 3. Take the BEFORE screenshot (baseline)

# 4. Launch the attack
./scripts/dos-test.sh

# 5. Take the DURING screenshot while it's running (during the attack)

# 6. After the run (240s) completes, take the AFTER screenshot
#    (recovery)

# 7. The slowhttptest tool writes its own report:
ls -lh reports/slowhttptest-*.html

# 8. Verify in Prometheus that the signature is visible
curl -sG http://localhost:9090/api/v1/query \
  --data-urlencode 'query=nginx_connections_active'
curl -sG http://localhost:9090/api/v1/query \
  --data-urlencode 'query=rate(nginx_connections_accepted[1m]) - rate(nginx_connections_handled[1m])'
# Expected during the attack: active is large, accepted-rate >> handled-rate
```

See [`dos-and-hardening.md`](dos-and-hardening.md) for the observed slowloris
signature and how the monitoring surfaces it.

---

## Hardening write-up

See [`dos-and-hardening.md`](dos-and-hardening.md) §Hardening for the layered
hardening proposal.