#!/bin/bash
# startup-script for Loadgen node — Day 2 (Cluster A: POC 4 — Intent Queue)
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

# --- Install Docker + Go ---
if ! command -v docker &>/dev/null; then
  apt-get update -qq
  apt-get install -y -qq docker.io docker-compose-v2 git
  systemctl enable docker && systemctl start docker
fi
if ! command -v go &>/dev/null; then
  curl -sL https://go.dev/dl/go1.24.2.linux-amd64.tar.gz | tar -C /usr/local -xz
  echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/profile.d/go.sh
  export PATH=$PATH:/usr/local/go/bin
fi
echo "[$(date)] Docker + Go ready"

# --- Clone repo ---
cd /opt
[ ! -d stg-seats-poc ] && git clone https://github.com/ffwd-org/stg-seats-poc.git
cd stg-seats-poc && git pull origin main

# --- Metrics stack ---
cd /opt/stg-seats-poc/infra
docker compose -f docker-compose.metrics.yml up -d

# --- Wait for Valkey ---
echo "[$(date)] Waiting for Valkey service node..."
for i in $(seq 1 120); do
  VALKEY_READY=$(gcloud compute instances describe poc-valkey \
    --zone="$ZONE" --format='value(metadata.items[ready])' 2>/dev/null || echo "")
  [ "$VALKEY_READY" = "true" ] && break
  sleep 5
done
[ "$VALKEY_READY" != "true" ] && { echo "ERROR: Valkey not ready"; exit 1; }

VALKEY_IP=$(gcloud compute instances describe poc-valkey \
  --zone="$ZONE" --format='value(networkInterfaces[0].networkIP)')
echo "[$(date)] Valkey IP: $VALKEY_IP"

# ============================================================
# POC 4: Intent Queue
# ============================================================
echo "[$(date)] ======== POC 4: Intent Queue ========"
cd /opt/stg-seats-poc/poc-4-intent-queue
go build -o bin/producer ./cmd/producer
go build -o bin/consumer ./cmd/consumer
go build -o bin/direct ./cmd/direct

# Seed Valkey with 100K seats for hold tests
cd /opt/stg-seats-poc/poc-1-valkey-contention
go build -o bin/seed ./cmd/seed
./bin/seed --mode=hset --seats=100000 --valkey-addr="$VALKEY_IP:6379"
cd /opt/stg-seats-poc/poc-4-intent-queue

# --- Phase A: Direct baseline ---
echo "[$(date)] POC 4: Direct baseline..."
./bin/direct --valkey-addr="$VALKEY_IP:6379" --rate=50000 --duration=120s &
DIRECT_PID=$!
wait $DIRECT_PID || true

# --- Phase B: Valkey Streams ---
echo "[$(date)] POC 4: Valkey Streams..."
./bin/consumer --queue=valkey-streams --valkey-addr="$VALKEY_IP:6379" \
  --batch-size=100 --batch-wait=10ms &
CONSUMER_PID=$!
sleep 2
./bin/producer --queue=valkey-streams --valkey-addr="$VALKEY_IP:6379" \
  --rate=50000 --duration=120s
kill $CONSUMER_PID 2>/dev/null; wait $CONSUMER_PID 2>/dev/null || true

# --- Phase C: NATS JetStream ---
echo "[$(date)] POC 4: Starting NATS..."
docker run -d --name nats --network=host nats:2.10 -js
sleep 3

echo "[$(date)] POC 4: NATS JetStream..."
./bin/consumer --queue=nats --nats-url="nats://localhost:4222" \
  --valkey-addr="$VALKEY_IP:6379" --batch-size=100 &
CONSUMER_PID=$!
sleep 2
./bin/producer --queue=nats --nats-url="nats://localhost:4222" \
  --rate=50000 --duration=120s
kill $CONSUMER_PID 2>/dev/null; wait $CONSUMER_PID 2>/dev/null || true
docker rm -f nats

# --- Phase D: Redpanda ---
echo "[$(date)] POC 4: Starting Redpanda..."
docker run -d --name redpanda --network=host \
  redpandadata/redpanda:v24.2.1 \
  redpanda start --smp 2 --memory 4G --overprovisioned \
  --kafka-addr 0.0.0.0:9092 --advertise-kafka-addr localhost:9092 \
  --node-id 0 --mode dev-container
sleep 10

echo "[$(date)] POC 4: Redpanda..."
./bin/consumer --queue=redpanda --redpanda-brokers="localhost:9092" \
  --valkey-addr="$VALKEY_IP:6379" --batch-size=100 &
CONSUMER_PID=$!
sleep 2
./bin/producer --queue=redpanda --redpanda-brokers="localhost:9092" \
  --rate=50000 --duration=120s
kill $CONSUMER_PID 2>/dev/null; wait $CONSUMER_PID 2>/dev/null || true
docker rm -f redpanda

# Upload results
gsutil -m cp -r results/ "$BUCKET/$RESULTS_PREFIX/poc-4/" 2>/dev/null || true
echo "[$(date)] POC 4 done, results uploaded"

# --- Signal done ---
cp /var/log/poc-startup.log /tmp/poc-startup.log
gsutil cp /tmp/poc-startup.log "$BUCKET/$RESULTS_PREFIX/poc-startup.log" 2>/dev/null || true
gcloud compute instances add-metadata "$INSTANCE" --zone="$ZONE" --metadata=done=true
echo "[$(date)] === Day 2 COMPLETE ==="
