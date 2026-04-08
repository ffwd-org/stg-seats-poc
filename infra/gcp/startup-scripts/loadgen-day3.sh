#!/bin/bash
# startup-script for Loadgen node — Day 3 (Cluster B: POC 2 + POC 5)
set -euo pipefail
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

# --- Install Docker + Go ---
apt-get update -qq
apt-get install -y -qq docker.io docker-compose-v2 git
systemctl enable docker && systemctl start docker
curl -sL https://go.dev/dl/go1.24.2.linux-amd64.tar.gz | tar -C /usr/local -xz
export PATH=$PATH:/usr/local/go/bin

# --- Clone repo ---
cd /opt
git clone https://github.com/ffwd-org/stg-seats-poc.git
cd stg-seats-poc && git pull origin main

# --- Metrics stack ---
cd /opt/stg-seats-poc/infra
docker compose -f docker-compose.metrics.yml up -d

# --- Wait for WS server (POC 2) ---
echo "[$(date)] Waiting for Go WS server..."
for i in $(seq 1 120); do
  READY=$(gcloud compute instances describe poc-appserver \
    --zone="$ZONE" --format='value(metadata.items[ready])' 2>/dev/null || echo "")
  [ "$READY" = "true" ] && break
  sleep 5
done
[ "$READY" != "true" ] && { echo "ERROR: WS server not ready"; exit 1; }

APP_IP=$(gcloud compute instances describe poc-appserver \
  --zone="$ZONE" --format='value(networkInterfaces[0].networkIP)')
echo "[$(date)] App server IP: $APP_IP"

# ============================================================
# POC 2: Go WebSocket Fan-out
# ============================================================
echo "[$(date)] ======== POC 2: Go WebSocket Fan-out ========"
cd /opt/stg-seats-poc/poc-2-websocket-fanout
go build -o bin/conngen ./cmd/conngen
go build -o bin/broadcaster ./cmd/broadcaster

# Phase A: Connection ramp (idle)
for CONNS in 10000 50000 100000 150000 200000 250000; do
  echo "[$(date)] POC 2: Ramping to $CONNS connections..."
  timeout 120 ./bin/conngen --target="ws://$APP_IP:8080/ws/event/1" \
    --connections=$CONNS --ramp-rate=5000 --metrics-port=2112 || true
  sleep 10
done

# Phase B: Single broadcast storm (at 250K)
echo "[$(date)] POC 2: Starting 250K connections for broadcast test..."
./bin/conngen --target="ws://$APP_IP:8080/ws/event/1" \
  --connections=250000 --ramp-rate=5000 --metrics-port=2112 &
CONN_PID=$!
sleep 60  # Wait for connections to establish

# Phase C: Sustained broadcast
for RATE in 1 10 100 500 1000; do
  echo "[$(date)] POC 2: Broadcast at $RATE/sec..."
  ./bin/broadcaster --target="http://$APP_IP:8080/broadcast/1" \
    --rate=$RATE --duration=120s
  sleep 5
done

kill $CONN_PID 2>/dev/null; wait $CONN_PID 2>/dev/null || true

# Upload POC 2 results
gsutil -m cp -r results/ "$BUCKET/$RESULTS_PREFIX/poc-2/" 2>/dev/null || true
echo "[$(date)] POC 2 done"

# --- Signal service node to swap to Centrifugo ---
gcloud compute instances add-metadata poc-appserver --zone="$ZONE" \
  --metadata=swap-to-centrifugo=true
echo "[$(date)] Signaled swap to Centrifugo"

# --- Wait for Centrifugo to be ready ---
echo "[$(date)] Waiting for Centrifugo..."
for i in $(seq 1 60); do
  READY5=$(gcloud compute instances describe poc-appserver \
    --zone="$ZONE" --format='value(metadata.items[ready-poc5])' 2>/dev/null || echo "")
  [ "$READY5" = "true" ] && break
  sleep 5
done
[ "$READY5" != "true" ] && { echo "ERROR: Centrifugo not ready"; exit 1; }

# ============================================================
# POC 5: Centrifugo Edge Offload
# ============================================================
echo "[$(date)] ======== POC 5: Centrifugo Edge Offload ========"
cd /opt/stg-seats-poc/poc-5-edge-offload
go build -o bin/conngen ./cmd/conngen
go build -o bin/broadcaster ./cmd/broadcaster

JWT_SECRET="poc-secret-key-for-jwt"
API_KEY="poc-api-key"

# Phase A: Connection ramp
for CONNS in 10000 50000 100000 150000 200000 250000; do
  echo "[$(date)] POC 5: Ramping to $CONNS connections..."
  timeout 120 ./bin/conngen --target="ws://$APP_IP:8000/connection/websocket" \
    --connections=$CONNS --ramp-rate=5000 --jwt-secret="$JWT_SECRET" \
    --channel="events:event-1" --metrics-port=2113 || true
  sleep 10
done

# Phase C: Sustained broadcast (at 250K connections)
echo "[$(date)] POC 5: Starting 250K connections..."
./bin/conngen --target="ws://$APP_IP:8000/connection/websocket" \
  --connections=250000 --ramp-rate=5000 --jwt-secret="$JWT_SECRET" \
  --channel="events:event-1" --metrics-port=2113 &
CONN_PID=$!
sleep 60

for RATE in 1 10 100 500 1000; do
  echo "[$(date)] POC 5: Broadcast at $RATE/sec..."
  ./bin/broadcaster --target="http://$APP_IP:8000" \
    --api-key="$API_KEY" --channel="events:event-1" \
    --rate=$RATE --duration=120s
  sleep 5
done

kill $CONN_PID 2>/dev/null; wait $CONN_PID 2>/dev/null || true

# Upload POC 5 results
gsutil -m cp -r results/ "$BUCKET/$RESULTS_PREFIX/poc-5/" 2>/dev/null || true
echo "[$(date)] POC 5 done"

# --- Signal all done ---
gcloud compute instances add-metadata poc-appserver --zone="$ZONE" --metadata=all-done=true
cp /var/log/poc-startup.log /tmp/poc-startup.log
gsutil cp /tmp/poc-startup.log "$BUCKET/$RESULTS_PREFIX/poc-startup.log" 2>/dev/null || true
gcloud compute instances add-metadata "$INSTANCE" --zone="$ZONE" --metadata=done=true
echo "[$(date)] === Day 3 COMPLETE ==="
