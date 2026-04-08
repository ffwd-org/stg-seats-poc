#!/bin/bash
# startup-script for WS/Centrifugo service node (Cluster B)
# Phase 1: runs Go WS server (POC 2), Phase 2: swaps to Centrifugo (POC 5)
#
# Day 2 lessons applied:
#   - set -uo (no -e) to avoid premature exit on kill/grep failures
#   - HOME/GOPATH/GOMODCACHE set explicitly for root
#   - Centrifugo uses --network=host (no bridge overhead for 250K conns)
set -uo pipefail
exec > >(tee /var/log/poc-startup.log) 2>&1

ZONE=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/zone | awk -F/ '{print $NF}')
INSTANCE=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/name)

echo "[$(date)] === WS/Centrifugo service node startup ==="

# --- OS Tuning (critical for 250K connections) ---
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
cd stg-seats-poc

# --- Phase 1: Build and start Go WS server (POC 2) ---
cd /opt/stg-seats-poc/poc-2-websocket-fanout
go build -o bin/wsserver ./cmd/wsserver
echo "[$(date)] WS server built"

# Start WS server with tuned GC
GOGC=100 GOMEMLIMIT=50GiB ./bin/wsserver --port=8080 --metrics-port=2112 &
WS_PID=$!
sleep 2
echo "[$(date)] Go WS server running (PID $WS_PID) on :8080"

# Signal ready for POC 2
gcloud compute instances add-metadata "$INSTANCE" --zone="$ZONE" --metadata=ready=true
echo "[$(date)] Phase 1 (Go WS) READY"

# --- Wait for loadgen to signal POC 2 is done ---
echo "[$(date)] Waiting for loadgen to finish POC 2..."
while true; do
  SWAP=$(gcloud compute instances describe "$INSTANCE" \
    --zone="$ZONE" --format='value(metadata.items[swap-to-centrifugo])' 2>/dev/null || echo "")
  [ "$SWAP" = "true" ] && break
  sleep 10
done

# --- Phase 2: Stop Go WS, start Centrifugo (POC 5) ---
echo "[$(date)] Swapping to Centrifugo..."
kill $WS_PID 2>/dev/null || true
wait $WS_PID 2>/dev/null || true

# Run Centrifugo with --network=host (avoids bridge NAT overhead for 250K connections)
docker run -d --name centrifugo --network=host \
  -v /opt/stg-seats-poc/poc-5-edge-offload/cmd/centrifugo/config.json:/centrifugo/config.json \
  centrifugo/centrifugo:v5 centrifugo -c /centrifugo/config.json
sleep 5
echo "[$(date)] Centrifugo running on :8000 (--network=host)"

# Signal ready for POC 5
gcloud compute instances add-metadata "$INSTANCE" --zone="$ZONE" --metadata=ready-poc5=true
echo "[$(date)] Phase 2 (Centrifugo) READY"

# Keep alive — loadgen will signal when fully done
while true; do
  ALLDONE=$(gcloud compute instances describe "$INSTANCE" \
    --zone="$ZONE" --format='value(metadata.items[all-done])' 2>/dev/null || echo "")
  [ "$ALLDONE" = "true" ] && break
  sleep 30
done
echo "[$(date)] === Service node shutting down ==="
