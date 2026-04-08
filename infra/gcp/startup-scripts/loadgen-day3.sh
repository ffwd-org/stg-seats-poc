#!/bin/bash
# startup-script for Loadgen node — Day 3 (Cluster B: POC 2 + POC 5)
#
# Tests:
#   POC 2 — Go WebSocket Fan-out (our own hub.Hub at 250K connections)
#   POC 5 — Centrifugo v5 Edge Offload (same test via Centrifugo)
#
# Phases per POC:
#   A — Connection ramp (10K → 250K idle connections)
#   B — Broadcast storm (250K connections, varying broadcast rates)
#
# Estimated runtime: ~90-120 minutes
#
# Day 2 lessons applied:
#   - set -uo (no -e) to avoid premature exit on kill/grep failures
#   - HOME/GOPATH/GOMODCACHE set explicitly for root
#   - Prometheus config written with real IPs BEFORE compose up
#   - All tool output redirected to result files
set -uo pipefail
exec > >(tee /var/log/poc-startup.log) 2>&1

ZONE=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/zone | awk -F/ '{print $NF}')
INSTANCE=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/name)
BUCKET="gs://stg-seats-poc-results"
RESULTS_PREFIX="cluster-b/$(date +%Y%m%d-%H%M)"

echo "[$(date)] === Loadgen Day 3 startup (POC 2 + POC 5) ==="

# --- OS Tuning (need 250K+ outbound connections) ---
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

# --- Wait for WS server (POC 2) ---
echo "[$(date)] Waiting for Go WS server on app node..."
READY=""
for i in $(seq 1 120); do
  READY=$(gcloud compute instances describe poc-appserver \
    --zone="$ZONE" --format='value(metadata.items[ready])' 2>/dev/null || echo "")
  [ "$READY" = "true" ] && break
  sleep 5
done
if [ "$READY" != "true" ]; then
  echo "[$(date)] ERROR: WS server not ready after 10 minutes"
  gcloud compute instances add-metadata "$INSTANCE" --zone="$ZONE" --metadata=done=error 2>/dev/null || true
  exit 1
fi

APP_IP=$(gcloud compute instances describe poc-appserver \
  --zone="$ZONE" --format='value(networkInterfaces[0].networkIP)')
echo "[$(date)] App server IP: $APP_IP"

# --- Write Prometheus config with real IPs (Day 2 lesson: BEFORE compose up) ---
cat > /opt/stg-seats-poc/infra/prometheus.yml <<PROMEOF
global:
  scrape_interval: 5s
scrape_configs:
  - job_name: poc2-wsserver
    static_configs:
      - targets: ['${APP_IP}:2112']
  - job_name: loadgen-conngen
    static_configs:
      - targets: ['localhost:2112']
  - job_name: loadgen-conngen-poc5
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
# POC 2: Go WebSocket Fan-out
# ============================================================
echo "[$(date)] ======== POC 2: Go WebSocket Fan-out ========"
cd /opt/stg-seats-poc/poc-2-websocket-fanout
go build -o bin/conngen ./cmd/conngen
go build -o bin/broadcaster ./cmd/broadcaster
echo "[$(date)] POC 2 binaries built"

mkdir -p results

# Phase A: Connection ramp (idle) — can we establish N connections?
echo "[$(date)] ---- Phase A: Connection Ramp ----"
for CONNS in 10000 50000 100000 150000 200000 250000; do
  echo "[$(date)] POC 2 Phase A: Ramping to $CONNS connections..."
  timeout 120 ./bin/conngen --target="ws://${APP_IP}:8080/ws/event/1" \
    --connections=$CONNS --ramp-rate=5000 --metrics-port=2112 \
    > "results/phaseA-ramp-${CONNS}.log" 2>&1 || true
  echo "[$(date)]   Result: $(tail -3 results/phaseA-ramp-${CONNS}.log 2>/dev/null || echo 'no output')"
  sleep 10
done

# Phase B: Sustained broadcast at 250K connections
echo "[$(date)] ---- Phase B: Broadcast Storm at 250K ----"
echo "[$(date)] POC 2 Phase B: Establishing 250K connections..."
./bin/conngen --target="ws://${APP_IP}:8080/ws/event/1" \
  --connections=250000 --ramp-rate=5000 --metrics-port=2112 \
  > results/phaseB-conngen-250k.log 2>&1 &
CONN_PID=$!
sleep 60  # Wait for connections to establish
echo "[$(date)]   Connections: $(tail -1 results/phaseB-conngen-250k.log 2>/dev/null || echo 'ramping...')"

for RATE in 1 10 100 500 1000; do
  echo "[$(date)] POC 2 Phase B: Broadcast at $RATE/sec for 120s..."
  ./bin/broadcaster --target="http://${APP_IP}:8080/broadcast/1" \
    --rate=$RATE --duration=120s \
    > "results/phaseB-broadcast-rate${RATE}.log" 2>&1
  echo "[$(date)]   Result: $(tail -3 results/phaseB-broadcast-rate${RATE}.log 2>/dev/null || echo 'no output')"
  sleep 5
done

kill $CONN_PID 2>/dev/null || true
wait $CONN_PID 2>/dev/null || true

# Upload POC 2 results
gsutil -m cp -r results/ "$BUCKET/$RESULTS_PREFIX/poc-2/" 2>/dev/null || true
echo "[$(date)] POC 2 complete, results uploaded"

# --- Signal service node to swap to Centrifugo ---
gcloud compute instances add-metadata poc-appserver --zone="$ZONE" \
  --metadata=swap-to-centrifugo=true
echo "[$(date)] Signaled swap to Centrifugo"

# --- Wait for Centrifugo to be ready ---
echo "[$(date)] Waiting for Centrifugo..."
READY5=""
for i in $(seq 1 60); do
  READY5=$(gcloud compute instances describe poc-appserver \
    --zone="$ZONE" --format='value(metadata.items[ready-poc5])' 2>/dev/null || echo "")
  [ "$READY5" = "true" ] && break
  sleep 5
done
if [ "$READY5" != "true" ]; then
  echo "[$(date)] ERROR: Centrifugo not ready after 5 minutes"
  # Continue anyway — upload what we have
  gcloud compute instances add-metadata "$INSTANCE" --zone="$ZONE" --metadata=done=error 2>/dev/null || true
  exit 1
fi

# ============================================================
# POC 5: Centrifugo Edge Offload
# ============================================================
echo "[$(date)] ======== POC 5: Centrifugo Edge Offload ========"
cd /opt/stg-seats-poc/poc-5-edge-offload
go build -o bin/conngen ./cmd/conngen
go build -o bin/broadcaster ./cmd/broadcaster
echo "[$(date)] POC 5 binaries built"

mkdir -p results

JWT_SECRET="poc-secret-key-for-jwt"
API_KEY="poc-api-key"

# Phase A: Connection ramp
echo "[$(date)] ---- Phase A: Connection Ramp (Centrifugo) ----"
for CONNS in 10000 50000 100000 150000 200000 250000; do
  echo "[$(date)] POC 5 Phase A: Ramping to $CONNS connections..."
  timeout 120 ./bin/conngen --target="ws://${APP_IP}:8000/connection/websocket" \
    --connections=$CONNS --ramp-rate=5000 --jwt-secret="$JWT_SECRET" \
    --channel="events:event-1" --metrics-port=2113 \
    > "results/phaseA-ramp-${CONNS}.log" 2>&1 || true
  echo "[$(date)]   Result: $(tail -3 results/phaseA-ramp-${CONNS}.log 2>/dev/null || echo 'no output')"
  sleep 10
done

# Phase B: Sustained broadcast at 250K connections
echo "[$(date)] ---- Phase B: Broadcast Storm at 250K (Centrifugo) ----"
echo "[$(date)] POC 5 Phase B: Establishing 250K connections..."
./bin/conngen --target="ws://${APP_IP}:8000/connection/websocket" \
  --connections=250000 --ramp-rate=5000 --jwt-secret="$JWT_SECRET" \
  --channel="events:event-1" --metrics-port=2113 \
  > results/phaseB-conngen-250k.log 2>&1 &
CONN_PID=$!
sleep 60
echo "[$(date)]   Connections: $(tail -1 results/phaseB-conngen-250k.log 2>/dev/null || echo 'ramping...')"

for RATE in 1 10 100 500 1000; do
  echo "[$(date)] POC 5 Phase B: Broadcast at $RATE/sec for 120s..."
  ./bin/broadcaster --target="http://${APP_IP}:8000" \
    --api-key="$API_KEY" --channel="events:event-1" \
    --rate=$RATE --duration=120s \
    > "results/phaseB-broadcast-rate${RATE}.log" 2>&1
  echo "[$(date)]   Result: $(tail -3 results/phaseB-broadcast-rate${RATE}.log 2>/dev/null || echo 'no output')"
  sleep 5
done

kill $CONN_PID 2>/dev/null || true
wait $CONN_PID 2>/dev/null || true

# Upload POC 5 results
gsutil -m cp -r results/ "$BUCKET/$RESULTS_PREFIX/poc-5/" 2>/dev/null || true
echo "[$(date)] POC 5 complete, results uploaded"

# --- Final upload + signal done ---
gcloud compute instances add-metadata poc-appserver --zone="$ZONE" --metadata=all-done=true 2>/dev/null || true
cp /var/log/poc-startup.log /tmp/poc-startup.log
gsutil cp /tmp/poc-startup.log "$BUCKET/$RESULTS_PREFIX/poc-startup.log" 2>/dev/null || true
gcloud compute instances add-metadata "$INSTANCE" --zone="$ZONE" --metadata=done=true 2>/dev/null || true
echo "[$(date)] === Day 3 COMPLETE ==="
