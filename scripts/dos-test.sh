#!/usr/bin/env bash
# Slow-HTTP (slowloris) load test against the nginx NodePort.
# Saves the slowhttptest CSV/HTML report into ./reports/.
#
# Usage: scripts/dos-test.sh [target_url]
#   default target: http://localhost:30080/
#
# What it does:
#   - launches a slowloris-style attack (-c 1000 connections, slow headers)
#   - runs for 240 seconds
#   - writes a report to ./reports/slowhttptest-<timestamp>.html

set -euo pipefail

TARGET="${1:-http://localhost:30080/}"
TS="$(date +%Y%m%d-%H%M%S)"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/reports/slowhttptest-${TS}"

command -v slowhttptest >/dev/null \
  || { echo "Install slowhttptest first (e.g. apt install slowhttptest / pacman -S slowhttptest)."; exit 1; }

mkdir -p "${ROOT}/reports"

echo "[*] Open the Grafana NGINX dashboard (auto-refresh 5s) before you continue."
read -rp "Press <Enter> when ready to launch the attack..." _

echo "[*] Attacking ${TARGET} — slowloris (slow-headers) mode for 240s"
slowhttptest \
  -c 1000 \
  -H \
  -g \
  -o "${OUT}" \
  -i 10 \
  -r 200 \
  -t GET \
  -u "${TARGET}" \
  -x 24 \
  -p 3 \
  -l 240

echo "[*] Report: ${OUT}.html  and  ${OUT}.csv"
echo "[*] Watch the dashboard: active/reading connections saturate during the run,"
echo "    then drain back to baseline within ~1 minute after it stops."
