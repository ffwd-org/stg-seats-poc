#!/bin/bash
# startup-script for Loadgen node — Day 4 (Cluster C: POC 6 — Elixir/BEAM)
#
# Tests: Elixir actor model with per-section GenServer, ETS concurrent reads
# Phases:
#   A — Latency vs Fragmentation (f=0,25,50,80 × 1 worker)
#   B — Concurrency at f=50 (100, 1K, 5K, 10K workers)
#   C — Worst case (f=80, 10K workers, 120s)
#   D — Quantity variation (qty=1,2,4,6,8 × 5K workers)
#   E — Hold throughput (50K workers, 120s)
#
# Day 2/3 lessons applied:
#   - set -uo (no -e)
#   - HOME/GOPATH/GOMODCACHE for root
#   - Prometheus config with real IPs BEFORE compose up
#   - All output redirected to result files
set -uo pipefail
exec > >(tee /var/log/poc-startup.log) 2>&1

ZONE=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/zone | awk -F/ '{print $NF}')
INSTANCE=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/name)
BUCKET="gs://stg-seats-poc-results"
RESULTS_PREFIX="cluster-c/$(date +%Y%m%d-%H%M)"

echo "[$(date)] === Loadgen Day 4 startup (POC 6: Elixir/BEAM) ==="

# --- OS Tuning ---
echo "* soft nofile 1048576" >> /etc/security/limits.conf
echo "* hard nofile 1048576" >> /etc/security/limits.conf
ulimit -n 1048576 || true
sysctl -w net.core.somaxconn=65535
sysctl -w net.ipv4.tcp_max_syn_backlog=65535
sysctl -w net.ipv4.ip_local_port_range="1024 65535"
sysctl -w net.ipv4.tcp_tw_reuse=1
sysctl -w net.core.netdev_max_backlog=65535
sysctl -w net.core.rmem_max=16777216
sysctl -w net.core.wmem_max=16777216
swapoff -a
echo "[$(date)] OS tuning done"

# --- Install Docker + Go ---
apt-get update -qq
apt-get install -y -qq docker.io docker-compose-v2 git
systemctl enable docker && systemctl start docker
curl -sL https://go.dev/dl/go1.24.2.linux-amd64.tar.gz | tar -C /usr/local -xz

# Day 2 lesson: must set these explicitly for root user
export PATH=$PATH:/usr/local/go/bin:/root/go/bin
export HOME=/root
export GOPATH=/root/go
export GOMODCACHE=/root/go/pkg/mod
mkdir -p "$GOPATH" "$GOMODCACHE"
echo "[$(date)] Docker + Go ready ($(go version))"

# --- Clone repo ---
cd /opt
git clone https://github.com/ffwd-org/stg-seats-poc.git
cd stg-seats-poc && git pull origin main

# --- Wait for Elixir service ---
echo "[$(date)] Waiting for Elixir service node..."
READY=""
for i in $(seq 1 180); do
  READY=$(gcloud compute instances describe poc-elixir \
    --zone="$ZONE" --format='value(metadata.items[ready])' 2>/dev/null || echo "")
  [ "$READY" = "true" ] && break
  sleep 5
done
if [ "$READY" != "true" ]; then
  echo "[$(date)] ERROR: Elixir node not ready after 15 minutes"
  gcloud compute instances add-metadata "$INSTANCE" --zone="$ZONE" --metadata=done=error 2>/dev/null || true
  exit 1
fi

ELIXIR_IP=$(gcloud compute instances describe poc-elixir \
  --zone="$ZONE" --format='value(networkInterfaces[0].networkIP)')
echo "[$(date)] Elixir IP: $ELIXIR_IP"

# --- Write Prometheus config with real IPs (Day 2 lesson: BEFORE compose up) ---
cat > /opt/stg-seats-poc/infra/prometheus.yml <<PROMEOF
global:
  scrape_interval: 5s
scrape_configs:
  - job_name: loadgen
    static_configs:
      - targets: ['localhost:2112']
  - job_name: elixir
    static_configs:
      - targets: ['${ELIXIR_IP}:4000']
    metrics_path: /metrics
PROMEOF

# --- Start Metrics stack ---
cd /opt/stg-seats-poc/infra
docker compose -f docker-compose.metrics.yml up -d
echo "[$(date)] Prometheus + Grafana running on :9090 / :3000"

# ============================================================
# POC 6: Actor Model Engine
# ============================================================
echo "[$(date)] ======== POC 6: Elixir/BEAM Actor Model ========"
cd /opt/stg-seats-poc/poc-6-actor-model
go build -o bin/loadgen ./cmd/loadgen
echo "[$(date)] Loadgen binary built"

mkdir -p results

# Helper: run a test and capture output
run_test() {
  local LABEL=$1 FRAG=$2 WORKERS=$3 DURATION=$4 QTY=$5
  echo "[$(date)] >>> $LABEL (frag=$FRAG workers=$WORKERS dur=$DURATION qty=$QTY)"

  # Seed venue with fragmentation
  curl -sf -X POST "http://$ELIXIR_IP:4000/seed" \
    -H "Content-Type: application/json" \
    -d "{\"seats\":100000,\"sections\":20,\"rows_per_section\":100,\"seats_per_row\":50,\"fragmentation\":$FRAG,\"focal_row\":50,\"focal_index\":25}" \
    > "results/${LABEL}-seed.log" 2>&1 || echo "  seed failed"

  sleep 1

  # Run loadgen
  ./bin/loadgen --target="http://$ELIXIR_IP:4000" \
    --workers=$WORKERS --duration=$DURATION --quantity=$QTY --metrics-port=2112 \
    > "results/${LABEL}.log" 2>&1

  # Print summary
  SUMMARY=$(grep -E '(Results|ops:)' "results/${LABEL}.log" 2>/dev/null | tail -2)
  echo "[$(date)] <<< $LABEL: $SUMMARY"
  sleep 3
}

# ----------------------------------------------------------
# Phase A: Latency vs Fragmentation (single worker)
# ----------------------------------------------------------
echo "[$(date)] ---- Phase A: Latency vs Fragmentation ----"
for FRAG in 0 25 50 80; do
  run_test "phaseA-frag${FRAG}" "$FRAG" 1 30s 2
done

# ----------------------------------------------------------
# Phase B: Concurrency at 50% fragmentation
# ----------------------------------------------------------
echo "[$(date)] ---- Phase B: Concurrency Scaling ----"
for WORKERS in 100 1000 5000 10000; do
  run_test "phaseB-workers${WORKERS}" 50 "$WORKERS" 60s 2
done

# ----------------------------------------------------------
# Phase C: Worst case (80% fragmentation, 10K workers)
# ----------------------------------------------------------
echo "[$(date)] ---- Phase C: Worst Case ----"
run_test "phaseC-worst" 80 10000 120s 2

# ----------------------------------------------------------
# Phase D: Quantity variation (50% frag, 5K workers)
# ----------------------------------------------------------
echo "[$(date)] ---- Phase D: Quantity Variation ----"
for QTY in 1 2 4 6 8; do
  run_test "phaseD-qty${QTY}" 50 5000 60s "$QTY"
done

# ----------------------------------------------------------
# Phase E: Hold throughput (bonus — 50K workers)
# ----------------------------------------------------------
echo "[$(date)] ---- Phase E: Hold Throughput ----"
run_test "phaseE-throughput" 0 50000 120s 1

# ============================================================
# Upload results + signal done
# ============================================================
echo ""
echo "[$(date)] ======== All POC 6 tests complete ========"

RESULT_COUNT=$(ls results/*.log 2>/dev/null | wc -l)
echo "[$(date)] Result files: $RESULT_COUNT"

# Create summary
{
  echo "# POC 6 — Elixir/BEAM Actor Model Results"
  echo "# Generated: $(date)"
  echo ""
  for f in results/phase*.log; do
    echo "=== $(basename "$f") ==="
    grep -E '(Results|ops:|ops/s)' "$f" 2>/dev/null | tail -3
    echo ""
  done
} > results/summary.txt

echo "[$(date)] Uploading results to GCS..."
gsutil -m cp -r results/ "$BUCKET/$RESULTS_PREFIX/poc-6/" 2>/dev/null || true
cp /var/log/poc-startup.log /tmp/poc-startup.log
gsutil cp /tmp/poc-startup.log "$BUCKET/$RESULTS_PREFIX/poc-startup.log" 2>/dev/null || true

gcloud compute instances add-metadata "$INSTANCE" --zone="$ZONE" --metadata=done=true 2>/dev/null || true
echo "[$(date)] === Day 4 COMPLETE ==="
