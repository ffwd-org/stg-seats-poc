#!/bin/bash
# startup-script for Loadgen node — Day 2 (Cluster A: POC 4 — Intent Queue)
#
# Tests: Valkey Streams vs NATS JetStream vs Redpanda
# Phases:
#   A — Variable rate throughput (1K/5K/10K/25K/50K ops/s)
#   B — Burst absorption (5K baseline → 50K spike → 5K recovery)
#   C — Batching variations (batch 1/10/50/100/500)
#   D — Multi-consumer scaling (1/2/4 consumers)
#
# Estimated runtime: ~60-75 minutes
set -euo pipefail
exec > >(tee /var/log/poc-startup.log) 2>&1

ZONE=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/zone | awk -F/ '{print $NF}')
INSTANCE=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/name)
BUCKET="gs://stg-seats-poc-results"
RESULTS_PREFIX="cluster-a-day2/$(date +%Y%m%d-%H%M)"

echo "[$(date)] === Loadgen Day 2 startup (POC 4: Intent Queue) ==="

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
if ! command -v docker &>/dev/null; then
  apt-get update -qq
  apt-get install -y -qq docker.io docker-compose-v2 git
  systemctl enable docker && systemctl start docker
fi
if ! command -v go &>/dev/null; then
  curl -sL https://go.dev/dl/go1.24.2.linux-amd64.tar.gz | tar -C /usr/local -xz
  echo 'export PATH=$PATH:/usr/local/go/bin:/root/go/bin' >> /etc/profile.d/go.sh
  export PATH=$PATH:/usr/local/go/bin:/root/go/bin
fi
echo "[$(date)] Docker + Go ready"

# --- Clone repo ---
cd /opt
[ ! -d stg-seats-poc ] && git clone https://github.com/ffwd-org/stg-seats-poc.git
cd stg-seats-poc && git pull origin main

# --- Wait for Valkey ---
echo "[$(date)] Waiting for Valkey service node..."
VALKEY_READY=""
for i in $(seq 1 120); do
  VALKEY_READY=$(gcloud compute instances describe poc-valkey \
    --zone="$ZONE" --format='value(metadata.items[ready])' 2>/dev/null || echo "")
  [ "$VALKEY_READY" = "true" ] && break
  echo "  ... waiting ($i/120)"
  sleep 5
done
if [ "$VALKEY_READY" != "true" ]; then
  echo "[$(date)] ERROR: Valkey not ready"
  gcloud compute instances add-metadata "$INSTANCE" --zone="$ZONE" --metadata=done=error
  exit 1
fi

VALKEY_IP=$(gcloud compute instances describe poc-valkey \
  --zone="$ZONE" --format='value(networkInterfaces[0].networkIP)')
echo "[$(date)] Valkey IP: $VALKEY_IP"

# --- Write Prometheus config with real IPs (Day 1 lesson: must write BEFORE compose up) ---
cat > /opt/stg-seats-poc/infra/prometheus.yml <<PROMEOF
global:
  scrape_interval: 5s
scrape_configs:
  - job_name: loadgen-producer
    static_configs:
      - targets: ['localhost:2112']
  - job_name: loadgen-consumer
    static_configs:
      - targets: ['localhost:2113']
  - job_name: valkey
    static_configs:
      - targets: ['${VALKEY_IP}:9121']
PROMEOF

# --- Start Metrics stack ---
cd /opt/stg-seats-poc/infra
docker compose -f docker-compose.metrics.yml up -d
echo "[$(date)] Prometheus + Grafana running on :9090 / :3000"

# ============================================================
# POC 4: Intent Queue — Full Test Suite
# ============================================================
echo "[$(date)] ======== POC 4: Intent Queue ========"
cd /opt/stg-seats-poc/poc-4-intent-queue
go build -o bin/producer ./cmd/producer
go build -o bin/consumer ./cmd/consumer
go build -o bin/direct ./cmd/direct
echo "[$(date)] POC 4 binaries built"

# Seed Valkey with 100K seats for hold tests
cd /opt/stg-seats-poc/poc-1-valkey-contention
go build -o bin/seed ./cmd/seed
./bin/seed --mode=hset --seats=100000 --valkey-addr="$VALKEY_IP:6379"
echo "[$(date)] Valkey seeded with 100K seats"
cd /opt/stg-seats-poc/poc-4-intent-queue

mkdir -p results

# ============================================================
# Helper functions
# ============================================================

start_broker() {
  local QUEUE=$1
  case $QUEUE in
    nats)
      echo "[$(date)] Starting NATS container..."
      docker run -d --name nats-poc4 --network=host nats:2.10 -js
      sleep 3
      echo "[$(date)] NATS ready"
      ;;
    redpanda)
      echo "[$(date)] Starting Redpanda container..."
      docker run -d --name redpanda-poc4 --network=host \
        redpandadata/redpanda:v24.2.1 \
        redpanda start --smp 2 --memory 4G --overprovisioned \
        --kafka-addr 0.0.0.0:9092 --advertise-kafka-addr localhost:9092 \
        --node-id 0 --mode dev-container
      sleep 10
      echo "[$(date)] Redpanda ready"
      ;;
    valkey-streams)
      echo "[$(date)] Valkey Streams — no broker needed"
      ;;
  esac
}

stop_broker() {
  local QUEUE=$1
  case $QUEUE in
    nats)
      docker rm -f nats-poc4 2>/dev/null || true
      echo "[$(date)] NATS stopped"
      ;;
    redpanda)
      docker rm -f redpanda-poc4 2>/dev/null || true
      echo "[$(date)] Redpanda stopped"
      ;;
    valkey-streams)
      # No cleanup needed — consumer only reads new messages via XREADGROUP >
      echo "[$(date)] Valkey Streams — no broker to stop"
      ;;
  esac
}

# Build consumer CLI args for a given queue
consumer_args() {
  local QUEUE=$1 BATCH=$2 CONSUMERS=$3
  local ARGS="--queue=$QUEUE --valkey-addr=$VALKEY_IP:6379 --batch-size=$BATCH --consumers=$CONSUMERS --metrics-port=2113"
  case $QUEUE in
    nats)       ARGS="$ARGS --nats-url=nats://localhost:4222" ;;
    redpanda)   ARGS="$ARGS --redpanda-brokers=localhost:9092" ;;
  esac
  echo "$ARGS"
}

# Build producer CLI args for a given queue
producer_args() {
  local QUEUE=$1 RATE=$2 DURATION=$3
  local ARGS="--queue=$QUEUE --rate=$RATE --duration=$DURATION --metrics-port=2112"
  case $QUEUE in
    nats)            ARGS="$ARGS --nats-url=nats://localhost:4222" ;;
    redpanda)        ARGS="$ARGS --redpanda-brokers=localhost:9092" ;;
    valkey-streams)  ARGS="$ARGS --valkey-addr=$VALKEY_IP:6379" ;;
  esac
  echo "$ARGS"
}

# Run one test: start consumer, run producer, capture output
run_test() {
  local QUEUE=$1 RATE=$2 DURATION=$3 BATCH=$4 CONSUMERS=$5 LABEL=$6

  echo "[$(date)] >>> Test: $LABEL (queue=$QUEUE rate=$RATE dur=$DURATION batch=$BATCH consumers=$CONSUMERS)"

  local CONS_ARGS
  CONS_ARGS=$(consumer_args "$QUEUE" "$BATCH" "$CONSUMERS")
  local PROD_ARGS
  PROD_ARGS=$(producer_args "$QUEUE" "$RATE" "$DURATION")

  # Start consumer in background
  ./bin/consumer $CONS_ARGS > "results/${LABEL}-consumer.log" 2>&1 &
  local CONSUMER_PID=$!
  sleep 2

  # Run producer (blocks until duration elapses)
  ./bin/producer $PROD_ARGS > "results/${LABEL}-producer.log" 2>&1

  # Give consumer 5s to drain remaining queued messages
  sleep 5

  # Gracefully stop consumer
  kill -TERM $CONSUMER_PID 2>/dev/null || true
  wait $CONSUMER_PID 2>/dev/null || true

  # Print final lines for log visibility
  echo "[$(date)] <<< $LABEL results:"
  echo "  Producer: $(tail -1 results/${LABEL}-producer.log 2>/dev/null || echo 'no output')"
  echo "  Consumer: $(grep 'FINAL' results/${LABEL}-consumer.log 2>/dev/null || tail -1 results/${LABEL}-consumer.log 2>/dev/null || echo 'no output')"

  sleep 3
}

# ============================================================
# Run all phases for each queue type
# Grouping by queue minimizes broker start/stop overhead
# ============================================================

for QUEUE in valkey-streams nats redpanda; do
  echo ""
  echo "[$(date)] ================================================================"
  echo "[$(date)] ===  QUEUE: $QUEUE  ==="
  echo "[$(date)] ================================================================"

  start_broker "$QUEUE"

  # ----------------------------------------------------------
  # Phase A: Variable Rate Throughput
  # Measures max sustainable throughput at different producer rates
  # ----------------------------------------------------------
  echo "[$(date)] ---- Phase A: Variable Rate Throughput ($QUEUE) ----"
  for RATE in 1000 5000 10000 25000 50000; do
    run_test "$QUEUE" "$RATE" "60s" "100" "1" "phaseA-${QUEUE}-rate${RATE}"
  done

  # ----------------------------------------------------------
  # Phase B: Burst Absorption
  # Baseline 5K/s → spike 50K/s for 10s → recovery 5K/s
  # Consumer stays running through all three producer phases
  # ----------------------------------------------------------
  echo "[$(date)] ---- Phase B: Burst Absorption ($QUEUE) ----"

  CONS_ARGS=$(consumer_args "$QUEUE" "100" "1")
  ./bin/consumer $CONS_ARGS > "results/phaseB-${QUEUE}-consumer.log" 2>&1 &
  BURST_CONSUMER_PID=$!
  sleep 2

  PROD_BASE=$(producer_args "$QUEUE" "5000" "30s")

  echo "[$(date)] Burst baseline: 5K/s for 30s"
  ./bin/producer $PROD_BASE > "results/phaseB-${QUEUE}-baseline.log" 2>&1

  PROD_SPIKE=$(producer_args "$QUEUE" "50000" "10s")
  echo "[$(date)] Burst spike: 50K/s for 10s"
  ./bin/producer $PROD_SPIKE > "results/phaseB-${QUEUE}-spike.log" 2>&1

  PROD_RECOVERY=$(producer_args "$QUEUE" "5000" "30s")
  echo "[$(date)] Burst recovery: 5K/s for 30s"
  ./bin/producer $PROD_RECOVERY > "results/phaseB-${QUEUE}-recovery.log" 2>&1

  sleep 5
  kill -TERM $BURST_CONSUMER_PID 2>/dev/null || true
  wait $BURST_CONSUMER_PID 2>/dev/null || true

  echo "[$(date)] Phase B results:"
  echo "  Consumer: $(grep 'FINAL' results/phaseB-${QUEUE}-consumer.log 2>/dev/null || echo 'no output')"
  echo "  Baseline: $(tail -1 results/phaseB-${QUEUE}-baseline.log 2>/dev/null || echo 'no output')"
  echo "  Spike:    $(tail -1 results/phaseB-${QUEUE}-spike.log 2>/dev/null || echo 'no output')"
  echo "  Recovery: $(tail -1 results/phaseB-${QUEUE}-recovery.log 2>/dev/null || echo 'no output')"

  sleep 3

  # ----------------------------------------------------------
  # Phase C: Batching Variations
  # Fixed rate 25K/s, vary consumer batch size
  # ----------------------------------------------------------
  echo "[$(date)] ---- Phase C: Batching Variations ($QUEUE) ----"
  for BATCH in 1 10 50 100 500; do
    run_test "$QUEUE" "25000" "60s" "$BATCH" "1" "phaseC-${QUEUE}-batch${BATCH}"
  done

  # ----------------------------------------------------------
  # Phase D: Multi-Consumer Scaling
  # Fixed rate 50K/s, vary consumer goroutine count
  # ----------------------------------------------------------
  echo "[$(date)] ---- Phase D: Multi-Consumer Scaling ($QUEUE) ----"
  for CONSUMERS in 1 2 4; do
    run_test "$QUEUE" "50000" "60s" "100" "$CONSUMERS" "phaseD-${QUEUE}-cons${CONSUMERS}"
  done

  stop_broker "$QUEUE"

  echo "[$(date)] === All phases complete for $QUEUE ==="
  sleep 5
done

# ============================================================
# Upload results + signal done
# ============================================================
echo ""
echo "[$(date)] ======== All POC 4 tests complete ========"

# Count result files
RESULT_COUNT=$(ls results/*.log 2>/dev/null | wc -l)
echo "[$(date)] Result files: $RESULT_COUNT"

# Create a summary of all test results
{
  echo "# POC 4 — Intent Queue Results Summary"
  echo "# Generated: $(date)"
  echo "# VM: $INSTANCE ($ZONE)"
  echo ""
  for f in results/phase*.log; do
    echo "=== $(basename "$f") ==="
    grep -E '(produced=|consumed=|FINAL|errors=|avg_latency)' "$f" 2>/dev/null | tail -3
    echo ""
  done
} > results/summary.txt

echo "[$(date)] Uploading results to GCS..."
gsutil -m cp -r results/ "$BUCKET/$RESULTS_PREFIX/poc-4/" 2>/dev/null || true
cp /var/log/poc-startup.log /tmp/poc-startup.log
gsutil cp /tmp/poc-startup.log "$BUCKET/$RESULTS_PREFIX/poc-startup.log" 2>/dev/null || true

gcloud compute instances add-metadata "$INSTANCE" --zone="$ZONE" --metadata=done=true
echo "[$(date)] === Day 2 COMPLETE ==="
