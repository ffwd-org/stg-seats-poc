#!/bin/bash
# startup-script for Loadgen node — Day 1 (Cluster A: POC 1 + POC 3)
# Installs Go + Docker, clones repo, runs POC tests, uploads results to GCS
set -euo pipefail
exec > >(tee /var/log/poc-startup.log) 2>&1

ZONE=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/zone | awk -F/ '{print $NF}')
INSTANCE=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/name)
PROJECT=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/project/project-id)
BUCKET="gs://stg-seats-poc-results"
RESULTS_PREFIX="cluster-a-day1/$(date +%Y%m%d-%H%M)"

echo "[$(date)] === Loadgen Day 1 startup ==="

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

# --- Install Docker ---
if ! command -v docker &>/dev/null; then
  apt-get update -qq
  apt-get install -y -qq docker.io docker-compose-v2 git
  systemctl enable docker
  systemctl start docker
fi
echo "[$(date)] Docker ready"

# --- Install Go 1.24 ---
if ! command -v go &>/dev/null; then
  curl -sL https://go.dev/dl/go1.24.2.linux-amd64.tar.gz | tar -C /usr/local -xz
  echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/profile.d/go.sh
fi
export PATH=$PATH:/usr/local/go/bin:/root/go/bin
export HOME=/root
export GOPATH=/root/go
export GOMODCACHE=/root/go/pkg/mod
mkdir -p "$GOPATH" "$GOMODCACHE"
echo "[$(date)] Go $(go version) ready"

# --- Clone repo ---
cd /opt
if [ ! -d stg-seats-poc ]; then
  git clone https://github.com/ffwd-org/stg-seats-poc.git
fi
cd stg-seats-poc
git pull origin main
echo "[$(date)] Repo cloned"

# --- Start Prometheus + Grafana ---
cd /opt/stg-seats-poc/infra
docker compose -f docker-compose.metrics.yml up -d
echo "[$(date)] Prometheus + Grafana running on :9090 / :3000"

# --- Discover Valkey IP ---
echo "[$(date)] Waiting for Valkey service node..."
for i in $(seq 1 120); do
  VALKEY_READY=$(gcloud compute instances describe poc-valkey \
    --zone="$ZONE" --format='value(metadata.items[ready])' 2>/dev/null || echo "")
  [ "$VALKEY_READY" = "true" ] && break
  echo "  ... waiting ($i/120)"
  sleep 5
done

if [ "$VALKEY_READY" != "true" ]; then
  echo "[$(date)] ERROR: Valkey node never became ready"
  gcloud compute instances add-metadata "$INSTANCE" --zone="$ZONE" --metadata=done=error
  exit 1
fi

VALKEY_IP=$(gcloud compute instances describe poc-valkey \
  --zone="$ZONE" --format='value(networkInterfaces[0].networkIP)')
echo "[$(date)] Valkey IP: $VALKEY_IP"

# --- Update Prometheus config with Valkey target and restart ---
cat > /opt/stg-seats-poc/infra/prometheus.yml <<PROMEOF
global:
  scrape_interval: 5s
scrape_configs:
  - job_name: loadgen
    static_configs:
      - targets: ['localhost:2112']
  - job_name: valkey
    static_configs:
      - targets: ['${VALKEY_IP}:9121']
PROMEOF
cd /opt/stg-seats-poc/infra
docker compose -f docker-compose.metrics.yml down
docker compose -f docker-compose.metrics.yml up -d
echo "[$(date)] Prometheus restarted with Valkey target"

# ============================================================
# POC 1: Valkey Contention (HSET vs BITFIELD)
# ============================================================
echo "[$(date)] ======== POC 1: Valkey Contention ========"
cd /opt/stg-seats-poc/poc-1-valkey-contention
go build -o bin/seed ./cmd/seed
go build -o bin/loadgen ./cmd/loadgen
echo "[$(date)] POC 1 binaries built"

# Seed HSET
echo "[$(date)] POC 1: Seeding HSET..."
./bin/seed --mode=hset --seats=100000 --valkey-addr="$VALKEY_IP:6379"

# Run HSET benchmark
echo "[$(date)] POC 1: Running HSET benchmark..."
./bin/loadgen --mode=hset --seats=100000 --valkey-addr="$VALKEY_IP:6379" \
  --ramp="100,1000,5000,10000,25000,50000,100000" --duration=60s

# Flush and seed BITFIELD
docker exec -i valkey valkey-cli -h "$VALKEY_IP" FLUSHDB 2>/dev/null || \
  apt-get install -y -qq valkey-tools 2>/dev/null && valkey-cli -h "$VALKEY_IP" FLUSHDB || true
# Use the seed tool to reset
echo "[$(date)] POC 1: Seeding BITFIELD..."
./bin/seed --mode=bitfield --seats=100000 --valkey-addr="$VALKEY_IP:6379"

# Run BITFIELD benchmark
echo "[$(date)] POC 1: Running BITFIELD benchmark..."
./bin/loadgen --mode=bitfield --seats=100000 --valkey-addr="$VALKEY_IP:6379" \
  --ramp="100,1000,5000,10000,25000,50000,100000" --duration=60s

# Upload POC 1 results
gsutil -m cp -r results/ "$BUCKET/$RESULTS_PREFIX/poc-1/" 2>/dev/null || true
echo "[$(date)] POC 1 done, results uploaded"

# ============================================================
# POC 3: Best Available
# ============================================================
echo "[$(date)] ======== POC 3: Best Available ========"
cd /opt/stg-seats-poc/poc-3-best-available
go build -o bin/seed ./cmd/seed
go build -o bin/loadgen ./cmd/loadgen
echo "[$(date)] POC 3 binaries built"

# Phase A: Latency vs Fragmentation (single worker)
for FRAG in 0 25 50 80; do
  echo "[$(date)] POC 3: Seeding f=$FRAG..."
  ./bin/seed --fragmentation=$FRAG --seats=100000 --valkey-addr="$VALKEY_IP:6379"

  echo "[$(date)] POC 3: Testing f=$FRAG, 1 worker..."
  ./bin/loadgen --workers=1 --duration=30s --quantity=2 \
    --valkey-addr="$VALKEY_IP:6379" --fragmentation=$FRAG
done

# Phase B: Concurrency at 50% fragmentation
echo "[$(date)] POC 3: Seeding f=50 for concurrency test..."
./bin/seed --fragmentation=50 --seats=100000 --valkey-addr="$VALKEY_IP:6379"

for WORKERS in 100 1000 5000 10000; do
  echo "[$(date)] POC 3: Testing f=50, workers=$WORKERS..."
  ./bin/loadgen --workers=$WORKERS --duration=60s --quantity=2 \
    --valkey-addr="$VALKEY_IP:6379" --fragmentation=50
done

# Phase C: Worst case (80% + 10K workers)
echo "[$(date)] POC 3: Seeding f=80 for worst case..."
./bin/seed --fragmentation=80 --seats=100000 --valkey-addr="$VALKEY_IP:6379"
echo "[$(date)] POC 3: Testing f=80, workers=10000..."
./bin/loadgen --workers=10000 --duration=120s --quantity=2 \
  --valkey-addr="$VALKEY_IP:6379" --fragmentation=80

# Phase D: Quantity variation at 50%
echo "[$(date)] POC 3: Seeding f=50 for quantity test..."
./bin/seed --fragmentation=50 --seats=100000 --valkey-addr="$VALKEY_IP:6379"
for QTY in 1 2 4 6 8; do
  echo "[$(date)] POC 3: Testing f=50, qty=$QTY, workers=5000..."
  ./bin/loadgen --workers=5000 --duration=60s --quantity=$QTY \
    --valkey-addr="$VALKEY_IP:6379" --fragmentation=50
done

# Upload POC 3 results
gsutil -m cp -r results/ "$BUCKET/$RESULTS_PREFIX/poc-3/" 2>/dev/null || true
echo "[$(date)] POC 3 done, results uploaded"

# ============================================================
# Upload logs + signal done
# ============================================================
cp /var/log/poc-startup.log /opt/stg-seats-poc/poc-startup.log
gsutil cp /opt/stg-seats-poc/poc-startup.log "$BUCKET/$RESULTS_PREFIX/poc-startup.log" 2>/dev/null || true

gcloud compute instances add-metadata "$INSTANCE" --zone="$ZONE" --metadata=done=true
echo "[$(date)] === Day 1 COMPLETE ==="
