#!/bin/bash
# startup-script for Loadgen node — Day 5b (Cluster B: POC 5 failure modes)
#
# Missing data reruns:
#   POC 5 Phase D — Go Backend Load (publish rate with Centrifugo handling 250K conns)
#   POC 5 Phase E — Failure Modes (kill/restart Centrifugo, measure reconnection)
#
# Day 3 lessons applied:
#   - set -uo (no -e)
#   - HOME/GOPATH/GOMODCACHE for root
#   - Multi-IP for >64K connections
#   - Prometheus config with real IPs BEFORE compose up
set -uo pipefail
exec > >(tee /var/log/poc-startup.log) 2>&1

ZONE=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/zone | awk -F/ '{print $NF}')
INSTANCE=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/name)
BUCKET="gs://stg-seats-poc-results"
RESULTS_PREFIX="day5b/$(date +%Y%m%d-%H%M)"

echo "[$(date)] === Loadgen Day 5b startup (POC 5 failure modes) ==="

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

# --- Wait for Centrifugo service ---
echo "[$(date)] Waiting for Centrifugo service node..."
READY=""
for i in $(seq 1 120); do
  READY=$(gcloud compute instances describe poc-appserver \
    --zone="$ZONE" --format='value(metadata.items[ready])' 2>/dev/null || echo "")
  [ "$READY" = "true" ] && break
  sleep 5
done
if [ "$READY" != "true" ]; then
  echo "[$(date)] ERROR: Centrifugo node not ready after 10 minutes"
  gcloud compute instances add-metadata "$INSTANCE" --zone="$ZONE" --metadata=done=error 2>/dev/null || true
  exit 1
fi

APP_IP=$(gcloud compute instances describe poc-appserver \
  --zone="$ZONE" --format='value(networkInterfaces[0].networkIP)')
echo "[$(date)] Centrifugo IP: $APP_IP"

# --- Setup multi-IP for >64K connections ---
echo "[$(date)] Setting up alias IPs for multi-IP connections..."
# Detect the primary network interface
PRIMARY_IF=$(ip route get 10.128.0.1 2>/dev/null | grep -oP 'dev \K\S+' || echo "ens4")
MY_IP=$(ip -4 addr show "$PRIMARY_IF" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
echo "[$(date)] Primary interface: $PRIMARY_IF, IP: $MY_IP"

# Add alias IPs (10.128.10.1-4) for source IP multiplexing
gcloud compute instances network-interfaces update "$INSTANCE" --zone="$ZONE" \
  --aliases="10.128.10.0/28" 2>/dev/null || echo "Alias IPs may already be configured"

for ALIAS_IP in 10.128.10.1 10.128.10.2 10.128.10.3 10.128.10.4; do
  ip addr add "$ALIAS_IP/32" dev "$PRIMARY_IF" 2>/dev/null || true
done
echo "[$(date)] Alias IPs configured"

# --- Write Prometheus config ---
cat > /opt/stg-seats-poc/infra/prometheus.yml <<PROMEOF
global:
  scrape_interval: 5s
scrape_configs:
  - job_name: conngen
    static_configs:
      - targets: ['localhost:2113']
  - job_name: centrifugo
    static_configs:
      - targets: ['${APP_IP}:9000']
    metrics_path: /metrics
PROMEOF

# --- Start Metrics stack ---
cd /opt/stg-seats-poc/infra
docker compose -f docker-compose.metrics.yml up -d
echo "[$(date)] Prometheus + Grafana running on :9090 / :3000"

# ============================================================
# POC 5 RERUN: Failure Modes
# ============================================================
echo ""
echo "[$(date)] ======== POC 5 RERUN: Failure Modes ========"
cd /opt/stg-seats-poc/poc-5-edge-offload
go build -o bin/conngen ./cmd/conngen
go build -o bin/broadcaster ./cmd/broadcaster
echo "[$(date)] POC 5 binaries built"

mkdir -p results/failure-modes

SOURCE_IPS="10.128.10.1,10.128.10.2,10.128.10.3,10.128.10.4"

# ----------------------------------------------------------
# Phase D: Go Backend Load Measurement
# Measure publish latency with 250K active connections
# ----------------------------------------------------------
echo "[$(date)] ---- Phase D: Go Backend Load ----"

# Start conngen (250K connections) in background
echo "[$(date)] Ramping 250K connections..."
setsid nohup ./bin/conngen \
  --target="ws://$APP_IP:8000/connection/websocket" \
  --connections=250000 \
  --ramp-rate=5000 \
  --channel="events:event-1" \
  --jwt-secret="poc-secret-key-for-jwt" \
  --source-ips="$SOURCE_IPS" \
  --metrics-port=2113 \
  > results/conngen.log 2>&1 &
CONNGEN_PID=$!
echo "[$(date)] Conngen started (PID=$CONNGEN_PID)"

# Wait for connections to ramp up (250K @ 5K/sec = ~50s + buffer)
echo "[$(date)] Waiting 70s for connection ramp..."
sleep 70

# Check connection count
CONN_COUNT=$(curl -sf http://localhost:2113/metrics 2>/dev/null | grep -oP 'connected=\K\d+' || echo "unknown")
echo "[$(date)] Connected clients: $CONN_COUNT"

# Run backend load test — increasing publish rates
for RATE in 1 10 100 500 1000; do
  echo "[$(date)] Phase D: broadcast rate=$RATE/sec, duration=60s"
  ./bin/broadcaster \
    --target="http://$APP_IP:9000" \
    --api-key=poc-api-key \
    --channel="events:event-1" \
    --rate="$RATE" \
    --duration=60s \
    > "results/phaseD-rate${RATE}.log" 2>&1

  SUMMARY=$(grep -E '(Results|p50|p95|p99|errors)' "results/phaseD-rate${RATE}.log" 2>/dev/null | tail -3)
  echo "[$(date)] Rate=$RATE: $SUMMARY"
  sleep 5
done

echo "[$(date)] Phase D complete"

# ----------------------------------------------------------
# Phase E: Failure Mode Testing
# Kill Centrifugo, measure disconnection, restart, measure recovery
# ----------------------------------------------------------
echo "[$(date)] ---- Phase E: Failure Modes ----"

# E1: Baseline
echo "[$(date)] E1: Baseline metrics"
curl -sf "http://localhost:2113/metrics" > "results/failure-modes/e1-baseline.txt" 2>/dev/null || true
cat "results/failure-modes/e1-baseline.txt" 2>/dev/null

# Baseline broadcast
./bin/broadcaster \
  --target="http://$APP_IP:9000" \
  --api-key=poc-api-key \
  --channel="events:event-1" \
  --rate=10 \
  --duration=30s \
  > "results/failure-modes/e1-baseline-broadcast.log" 2>&1
echo "[$(date)] E1 baseline broadcast done"

# E2: Kill Centrifugo
echo "[$(date)] E2: Killing Centrifugo..."
KILL_TIME=$(date +%s)
# SSH to app server and stop Centrifugo
gcloud compute ssh poc-appserver --zone="$ZONE" --command="docker stop centrifugo" 2>/dev/null || \
  ssh -o StrictHostKeyChecking=no "$APP_IP" "docker stop centrifugo" 2>/dev/null || \
  echo "WARNING: Could not stop Centrifugo via SSH"

echo "[$(date)] Centrifugo stopped. Monitoring disconnection storm (60s)..."
for i in $(seq 1 12); do
  sleep 5
  STATS=$(curl -sf "http://localhost:2113/metrics" 2>/dev/null || echo "metrics unavailable")
  echo "[$(date)]   $(echo "$STATS" | head -4)"
done | tee "results/failure-modes/e2-disconnect-storm.log"

curl -sf "http://localhost:2113/metrics" > "results/failure-modes/e2-post-kill.txt" 2>/dev/null || true

# E3: Broadcast while down
echo "[$(date)] E3: Broadcasting while Centrifugo is down..."
./bin/broadcaster \
  --target="http://$APP_IP:9000" \
  --api-key=poc-api-key \
  --channel="events:event-1" \
  --rate=10 \
  --duration=10s \
  > "results/failure-modes/e3-broadcast-while-down.log" 2>&1 || true
echo "[$(date)] E3 done (expected failures)"

# E4: Restart Centrifugo
echo "[$(date)] E4: Restarting Centrifugo..."
RESTART_TIME=$(date +%s)
gcloud compute ssh poc-appserver --zone="$ZONE" --command="docker start centrifugo" 2>/dev/null || \
  ssh -o StrictHostKeyChecking=no "$APP_IP" "docker start centrifugo" 2>/dev/null || \
  echo "WARNING: Could not start Centrifugo via SSH"

echo "[$(date)] Centrifugo restarted. Monitoring reconnection storm (120s)..."
for i in $(seq 1 24); do
  sleep 5
  STATS=$(curl -sf "http://localhost:2113/metrics" 2>/dev/null || echo "metrics unavailable")
  echo "[$(date)]   $(echo "$STATS" | head -4)"
done | tee "results/failure-modes/e4-reconnect-storm.log"

curl -sf "http://localhost:2113/metrics" > "results/failure-modes/e4-post-restart.txt" 2>/dev/null || true

# E5: Post-recovery broadcast
echo "[$(date)] E5: Post-recovery broadcast..."
./bin/broadcaster \
  --target="http://$APP_IP:9000" \
  --api-key=poc-api-key \
  --channel="events:event-1" \
  --rate=10 \
  --duration=30s \
  > "results/failure-modes/e5-post-recovery-broadcast.log" 2>&1
echo "[$(date)] E5 done"

# Failure modes summary
DOWNTIME=$((RESTART_TIME - KILL_TIME))
{
  echo "# POC 5 — Failure Mode Results"
  echo "# Generated: $(date)"
  echo ""
  echo "## Timeline"
  echo "- Kill time: $(date -d @$KILL_TIME 2>/dev/null || date -r $KILL_TIME 2>/dev/null || echo $KILL_TIME)"
  echo "- Restart time: $(date -d @$RESTART_TIME 2>/dev/null || date -r $RESTART_TIME 2>/dev/null || echo $RESTART_TIME)"
  echo "- Downtime: ${DOWNTIME}s"
  echo ""
  echo "## E1: Baseline"
  cat "results/failure-modes/e1-baseline.txt" 2>/dev/null
  echo ""
  echo "## E2: Post-Kill"
  cat "results/failure-modes/e2-post-kill.txt" 2>/dev/null
  echo ""
  echo "## E4: Post-Restart"
  cat "results/failure-modes/e4-post-restart.txt" 2>/dev/null
  echo ""
  echo "## Phase D: Backend Load"
  for f in results/phaseD-rate*.log; do
    echo "### $(basename "$f")"
    grep -E '(Results|p50|p95|p99|errors|sent)' "$f" 2>/dev/null | tail -5
    echo ""
  done
  echo "## E1: Baseline Broadcast"
  grep -E '(Results|p50|p95|p99)' "results/failure-modes/e1-baseline-broadcast.log" 2>/dev/null | tail -3
  echo ""
  echo "## E3: Broadcast While Down"
  grep -E '(Results|errors|sent)' "results/failure-modes/e3-broadcast-while-down.log" 2>/dev/null | tail -3
  echo ""
  echo "## E5: Post-Recovery Broadcast"
  grep -E '(Results|p50|p95|p99)' "results/failure-modes/e5-post-recovery-broadcast.log" 2>/dev/null | tail -3
} > results/failure-modes-summary.txt

# Kill conngen
kill $CONNGEN_PID 2>/dev/null || true

echo ""
echo "[$(date)] ======== POC 5 failure modes rerun complete ========"

# ============================================================
# Upload results + signal done
# ============================================================
echo ""
echo "[$(date)] ======== All Day 5b tests complete ========"

echo "[$(date)] Uploading results to GCS..."
gsutil -m cp -r results/ "$BUCKET/$RESULTS_PREFIX/poc-5-failure/" 2>/dev/null || true
cp /var/log/poc-startup.log /tmp/poc-startup.log
gsutil cp /tmp/poc-startup.log "$BUCKET/$RESULTS_PREFIX/poc-startup.log" 2>/dev/null || true

gcloud compute instances add-metadata "$INSTANCE" --zone="$ZONE" --metadata=done=true 2>/dev/null || true
echo "[$(date)] === Day 5b COMPLETE ==="
