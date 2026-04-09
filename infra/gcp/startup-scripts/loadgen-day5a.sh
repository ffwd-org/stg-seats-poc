#!/bin/bash
# startup-script for Loadgen node — Day 5a (Cluster A: POC 1 memory + POC 4 latency)
#
# Missing data reruns:
#   POC 1 — HSET vs BITFIELD memory comparison (used_memory per mode)
#   POC 4 — E2E latency percentiles (p50/p95/p99) for all 3 queues
#
# Day 2/3 lessons applied:
#   - set -uo (no -e)
#   - HOME/GOPATH/GOMODCACHE for root
#   - Prometheus config with real IPs BEFORE compose up
set -uo pipefail
exec > >(tee /var/log/poc-startup.log) 2>&1

ZONE=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/zone | awk -F/ '{print $NF}')
INSTANCE=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/name)
BUCKET="gs://stg-seats-poc-results"
RESULTS_PREFIX="day5a/$(date +%Y%m%d-%H%M)"

echo "[$(date)] === Loadgen Day 5a startup (POC 1 memory + POC 4 latency) ==="

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

# --- Wait for Valkey+NATS service ---
echo "[$(date)] Waiting for Valkey+NATS service node..."
READY=""
for i in $(seq 1 120); do
  READY=$(gcloud compute instances describe poc-valkey \
    --zone="$ZONE" --format='value(metadata.items[ready])' 2>/dev/null || echo "")
  [ "$READY" = "true" ] && break
  sleep 5
done
if [ "$READY" != "true" ]; then
  echo "[$(date)] ERROR: Valkey node not ready after 10 minutes"
  gcloud compute instances add-metadata "$INSTANCE" --zone="$ZONE" --metadata=done=error 2>/dev/null || true
  exit 1
fi

VALKEY_IP=$(gcloud compute instances describe poc-valkey \
  --zone="$ZONE" --format='value(networkInterfaces[0].networkIP)')
echo "[$(date)] Valkey IP: $VALKEY_IP"

# --- Write Prometheus config ---
cat > /opt/stg-seats-poc/infra/prometheus.yml <<PROMEOF
global:
  scrape_interval: 5s
scrape_configs:
  - job_name: loadgen
    static_configs:
      - targets: ['localhost:2112']
  - job_name: valkey-exporter
    static_configs:
      - targets: ['${VALKEY_IP}:9121']
PROMEOF

# --- Start Metrics stack ---
cd /opt/stg-seats-poc/infra
docker compose -f docker-compose.metrics.yml up -d
echo "[$(date)] Prometheus + Grafana running on :9090 / :3000"

# ============================================================
# POC 1 RERUN: Memory Comparison (HSET vs BITFIELD)
# ============================================================
echo ""
echo "[$(date)] ======== POC 1 RERUN: Memory Comparison ========"
cd /opt/stg-seats-poc/poc-1-valkey-contention
go build -o bin/loadgen ./cmd/loadgen
go build -o bin/seed ./cmd/seed
echo "[$(date)] POC 1 binaries built"

mkdir -p results

# Helper: capture Valkey memory
capture_memory() {
  local LABEL=$1
  docker run --rm --network=host valkey/valkey:8.0 valkey-cli -h "$VALKEY_IP" INFO memory 2>/dev/null \
    | grep -E '^(used_memory:|used_memory_human:)' > "results/${LABEL}-memory.txt"
  echo "[$(date)] Memory ($LABEL): $(cat results/${LABEL}-memory.txt | tr '\n' ' ')"
}

# --- HSET memory test ---
echo "[$(date)] --- HSET memory test ---"
docker run --rm --network=host valkey/valkey:8.0 valkey-cli -h "$VALKEY_IP" FLUSHDB 2>/dev/null || true
capture_memory "hset-empty"

./bin/seed --mode=hset --seats=100000 --valkey-addr="$VALKEY_IP:6379"
capture_memory "hset-seeded"

# Run abbreviated loadgen (just 3 stages: 100, 1K, 10K) to capture memory under load
./bin/loadgen --mode=hset --valkey-addr="$VALKEY_IP:6379" \
  --seats=100000 --ramp=100,1000,10000 --duration=30s --cooldown=5s \
  --metrics-port=2112 \
  > results/hset-memory-run.log 2>&1
capture_memory "hset-post-load"

echo "[$(date)] HSET memory test complete"

# --- BITFIELD memory test ---
echo "[$(date)] --- BITFIELD memory test ---"
docker run --rm --network=host valkey/valkey:8.0 valkey-cli -h "$VALKEY_IP" FLUSHDB 2>/dev/null || true
capture_memory "bitfield-empty"

./bin/seed --mode=bitfield --seats=100000 --valkey-addr="$VALKEY_IP:6379"
capture_memory "bitfield-seeded"

./bin/loadgen --mode=bitfield --valkey-addr="$VALKEY_IP:6379" \
  --seats=100000 --ramp=100,1000,10000 --duration=30s --cooldown=5s \
  --metrics-port=2112 \
  > results/bitfield-memory-run.log 2>&1
capture_memory "bitfield-post-load"

echo "[$(date)] BITFIELD memory test complete"

# Create memory comparison summary
{
  echo "# POC 1 — Memory Comparison (HSET vs BITFIELD)"
  echo "# Generated: $(date)"
  echo ""
  echo "## HSET"
  for f in results/hset-*-memory.txt; do
    echo "### $(basename "$f" .txt)"
    cat "$f"
    echo ""
  done
  echo "## BITFIELD"
  for f in results/bitfield-*-memory.txt; do
    echo "### $(basename "$f" .txt)"
    cat "$f"
    echo ""
  done
  echo "## Loadgen CSV (HSET)"
  cat results/hset-run.csv 2>/dev/null || echo "(from hset-memory-run.log)"
  grep -E '(stage result|valkey_memory_mb)' results/hset-memory-run.log 2>/dev/null || true
  echo ""
  echo "## Loadgen CSV (BITFIELD)"
  cat results/bitfield-run.csv 2>/dev/null || echo "(from bitfield-memory-run.log)"
  grep -E '(stage result|valkey_memory_mb)' results/bitfield-memory-run.log 2>/dev/null || true
} > results/memory-comparison.txt

echo ""
echo "[$(date)] ======== POC 1 memory rerun complete ========"

# ============================================================
# POC 4 RERUN: E2E Latency Percentiles
# ============================================================
echo ""
echo "[$(date)] ======== POC 4 RERUN: E2E Latency ========"
cd /opt/stg-seats-poc/poc-4-intent-queue
go build -o bin/producer ./cmd/producer
go build -o bin/consumer ./cmd/consumer
echo "[$(date)] POC 4 binaries built"

mkdir -p results

# Flush Valkey for clean state
docker run --rm --network=host valkey/valkey:8.0 valkey-cli -h "$VALKEY_IP" FLUSHDB 2>/dev/null || true

# Seed seats for hold operations
cd /opt/stg-seats-poc/poc-1-valkey-contention
./bin/seed --mode=hset --seats=100000 --valkey-addr="$VALKEY_IP:6379"
cd /opt/stg-seats-poc/poc-4-intent-queue

# Helper: run latency test for a queue
run_latency_test() {
  local QUEUE=$1 RATE=$2 DURATION=$3 BATCH=$4 CONSUMERS=$5 LABEL=$6
  echo "[$(date)] >>> $LABEL ($QUEUE rate=$RATE batch=$BATCH consumers=$CONSUMERS)"

  # Build consumer args
  local CONS_ARGS="--queue=$QUEUE --valkey-addr=$VALKEY_IP:6379 --batch-size=$BATCH --consumers=$CONSUMERS --metrics-port=2113"
  local PROD_ARGS="--queue=$QUEUE --rate=$RATE --duration=$DURATION --metrics-port=2112"

  case $QUEUE in
    nats)
      CONS_ARGS="$CONS_ARGS --nats-url=nats://$VALKEY_IP:4222"
      PROD_ARGS="$PROD_ARGS --nats-url=nats://$VALKEY_IP:4222"
      ;;
    valkey-streams)
      PROD_ARGS="$PROD_ARGS --valkey-addr=$VALKEY_IP:6379"
      ;;
  esac

  # Start consumer in background
  ./bin/consumer $CONS_ARGS > "results/${LABEL}-consumer.log" 2>&1 &
  CONS_PID=$!
  sleep 2

  # Run producer
  ./bin/producer $PROD_ARGS > "results/${LABEL}-producer.log" 2>&1

  # Wait for consumer to drain (10s grace)
  sleep 10
  kill $CONS_PID 2>/dev/null || true
  wait $CONS_PID 2>/dev/null || true

  # Print latency summary
  echo "[$(date)] <<< $LABEL consumer output:"
  grep -E '(consumed|FINAL|p50|p95|p99|avg_latency)' "results/${LABEL}-consumer.log" 2>/dev/null | tail -5
  echo ""
  sleep 3
}

# ----------------------------------------------------------
# Phase: E2E Latency by Rate (batch=10, 1 consumer)
# Test at 5K, 25K, 50K rate for each queue
# ----------------------------------------------------------
echo "[$(date)] ---- E2E Latency by Rate ----"

for QUEUE in valkey-streams nats; do
  echo "[$(date)] == Queue: $QUEUE =="

  # Reset Valkey seats between queues
  docker run --rm --network=host valkey/valkey:8.0 valkey-cli -h "$VALKEY_IP" FLUSHDB 2>/dev/null || true
  cd /opt/stg-seats-poc/poc-1-valkey-contention
  ./bin/seed --mode=hset --seats=100000 --valkey-addr="$VALKEY_IP:6379"
  cd /opt/stg-seats-poc/poc-4-intent-queue

  for RATE in 5000 25000 50000; do
    run_latency_test "$QUEUE" "$RATE" "60s" 10 1 "latency-${QUEUE}-rate${RATE}"

    # Re-seed between runs
    docker run --rm --network=host valkey/valkey:8.0 valkey-cli -h "$VALKEY_IP" FLUSHDB 2>/dev/null || true
    cd /opt/stg-seats-poc/poc-1-valkey-contention
    ./bin/seed --mode=hset --seats=100000 --valkey-addr="$VALKEY_IP:6379"
    cd /opt/stg-seats-poc/poc-4-intent-queue
  done
done

# ----------------------------------------------------------
# Phase: Latency with multi-consumer (NATS, 50K rate)
# ----------------------------------------------------------
echo "[$(date)] ---- Latency with Multi-Consumer (NATS) ----"
for CONSUMERS in 1 2 4; do
  docker run --rm --network=host valkey/valkey:8.0 valkey-cli -h "$VALKEY_IP" FLUSHDB 2>/dev/null || true
  cd /opt/stg-seats-poc/poc-1-valkey-contention
  ./bin/seed --mode=hset --seats=100000 --valkey-addr="$VALKEY_IP:6379"
  cd /opt/stg-seats-poc/poc-4-intent-queue

  run_latency_test "nats" "50000" "60s" 10 "$CONSUMERS" "latency-nats-cons${CONSUMERS}"
done

# ----------------------------------------------------------
# Phase: Direct baseline (no queue, for comparison)
# ----------------------------------------------------------
echo "[$(date)] ---- Direct Baseline (no queue) ----"
docker run --rm --network=host valkey/valkey:8.0 valkey-cli -h "$VALKEY_IP" FLUSHDB 2>/dev/null || true
cd /opt/stg-seats-poc/poc-1-valkey-contention
./bin/seed --mode=hset --seats=100000 --valkey-addr="$VALKEY_IP:6379"

# Use POC 1 loadgen for direct baseline at comparable rates
./bin/loadgen --mode=hset --valkey-addr="$VALKEY_IP:6379" \
  --seats=100000 --ramp=5000,25000,50000 --duration=60s --cooldown=5s \
  --metrics-port=2112 \
  > /opt/stg-seats-poc/poc-4-intent-queue/results/latency-direct-baseline.log 2>&1

echo "[$(date)] Direct baseline:"
grep -E 'stage result' /opt/stg-seats-poc/poc-4-intent-queue/results/latency-direct-baseline.log 2>/dev/null | tail -5
cd /opt/stg-seats-poc/poc-4-intent-queue

# Create latency summary
{
  echo "# POC 4 — E2E Latency Comparison"
  echo "# Generated: $(date)"
  echo ""
  for f in results/latency-*.log; do
    echo "=== $(basename "$f") ==="
    grep -E '(FINAL|p50|p95|p99|avg_latency|stage result)' "$f" 2>/dev/null | tail -5
    echo ""
  done
} > results/latency-summary.txt

echo ""
echo "[$(date)] ======== POC 4 latency rerun complete ========"

# ============================================================
# Upload results + signal done
# ============================================================
echo ""
echo "[$(date)] ======== All Day 5a tests complete ========"

echo "[$(date)] Uploading results to GCS..."
cd /opt/stg-seats-poc
gsutil -m cp -r poc-1-valkey-contention/results/ "$BUCKET/$RESULTS_PREFIX/poc-1-memory/" 2>/dev/null || true
gsutil -m cp -r poc-4-intent-queue/results/ "$BUCKET/$RESULTS_PREFIX/poc-4-latency/" 2>/dev/null || true
cp /var/log/poc-startup.log /tmp/poc-startup.log
gsutil cp /tmp/poc-startup.log "$BUCKET/$RESULTS_PREFIX/poc-startup.log" 2>/dev/null || true

gcloud compute instances add-metadata "$INSTANCE" --zone="$ZONE" --metadata=done=true 2>/dev/null || true
echo "[$(date)] === Day 5a COMPLETE ==="
