#!/bin/bash
# startup-script for Loadgen node — Day 4 (Cluster C: POC 6 — Elixir/BEAM)
set -euo pipefail
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

# --- Wait for Elixir service ---
echo "[$(date)] Waiting for Elixir service node..."
for i in $(seq 1 180); do
  READY=$(gcloud compute instances describe poc-elixir \
    --zone="$ZONE" --format='value(metadata.items[ready])' 2>/dev/null || echo "")
  [ "$READY" = "true" ] && break
  sleep 5
done
[ "$READY" != "true" ] && { echo "ERROR: Elixir node not ready"; exit 1; }

ELIXIR_IP=$(gcloud compute instances describe poc-elixir \
  --zone="$ZONE" --format='value(networkInterfaces[0].networkIP)')
echo "[$(date)] Elixir IP: $ELIXIR_IP"

# ============================================================
# POC 6: Actor Model Engine
# ============================================================
echo "[$(date)] ======== POC 6: Elixir/BEAM Actor Model ========"
cd /opt/stg-seats-poc/poc-6-actor-model
go build -o bin/loadgen ./cmd/loadgen

# Phase A: Latency vs Fragmentation (single worker)
for FRAG in 0 25 50 80; do
  echo "[$(date)] POC 6: Seeding f=$FRAG..."
  curl -sf -X POST "http://$ELIXIR_IP:4000/seed" \
    -H "Content-Type: application/json" \
    -d "{\"seats\":100000,\"sections\":20,\"rows_per_section\":100,\"seats_per_row\":50,\"fragmentation\":$FRAG,\"focal_row\":50,\"focal_index\":25}"

  echo "[$(date)] POC 6: Testing f=$FRAG, 1 worker..."
  ./bin/loadgen --target="http://$ELIXIR_IP:4000" \
    --workers=1 --duration=30s --quantity=2
done

# Phase B: Concurrency at 50% fragmentation
echo "[$(date)] POC 6: Seeding f=50 for concurrency test..."
curl -sf -X POST "http://$ELIXIR_IP:4000/seed" \
  -H "Content-Type: application/json" \
  -d '{"seats":100000,"sections":20,"rows_per_section":100,"seats_per_row":50,"fragmentation":50,"focal_row":50,"focal_index":25}'

for WORKERS in 100 1000 5000 10000; do
  echo "[$(date)] POC 6: Testing f=50, workers=$WORKERS..."
  ./bin/loadgen --target="http://$ELIXIR_IP:4000" \
    --workers=$WORKERS --duration=60s --quantity=2
done

# Phase C: Worst case (80% + 10K workers)
echo "[$(date)] POC 6: Seeding f=80..."
curl -sf -X POST "http://$ELIXIR_IP:4000/seed" \
  -H "Content-Type: application/json" \
  -d '{"seats":100000,"sections":20,"rows_per_section":100,"seats_per_row":50,"fragmentation":80,"focal_row":50,"focal_index":25}'
echo "[$(date)] POC 6: Testing f=80, workers=10000..."
./bin/loadgen --target="http://$ELIXIR_IP:4000" \
  --workers=10000 --duration=120s --quantity=2

# Phase D: Quantity variation
echo "[$(date)] POC 6: Seeding f=50 for quantity test..."
curl -sf -X POST "http://$ELIXIR_IP:4000/seed" \
  -H "Content-Type: application/json" \
  -d '{"seats":100000,"sections":20,"rows_per_section":100,"seats_per_row":50,"fragmentation":50,"focal_row":50,"focal_index":25}'
for QTY in 1 2 4 6 8; do
  echo "[$(date)] POC 6: Testing f=50, qty=$QTY, workers=5000..."
  ./bin/loadgen --target="http://$ELIXIR_IP:4000" \
    --workers=5000 --duration=60s --quantity=$QTY
done

# Phase E: Hold throughput (bonus)
echo "[$(date)] POC 6: Hold throughput test..."
./bin/loadgen --target="http://$ELIXIR_IP:4000" \
  --workers=50000 --duration=120s --quantity=1

# Upload results
gsutil -m cp -r results/ "$BUCKET/$RESULTS_PREFIX/poc-6/" 2>/dev/null || true
echo "[$(date)] POC 6 done"

# --- Signal done ---
cp /var/log/poc-startup.log /tmp/poc-startup.log
gsutil cp /tmp/poc-startup.log "$BUCKET/$RESULTS_PREFIX/poc-startup.log" 2>/dev/null || true
gcloud compute instances add-metadata "$INSTANCE" --zone="$ZONE" --metadata=done=true
echo "[$(date)] === Day 4 COMPLETE ==="
