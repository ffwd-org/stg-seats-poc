#!/bin/bash
# startup-script for Elixir/BEAM service node (Cluster C)
#
# Day 2/3 lessons applied:
#   - set -uo (no -e) — Erlang package install has fallback path
#   - Uses Docker to run Elixir app (more reliable than bare-metal install)
set -uo pipefail
exec > >(tee /var/log/poc-startup.log) 2>&1

ZONE=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/zone | awk -F/ '{print $NF}')
INSTANCE=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/name)

echo "[$(date)] === Elixir service node startup ==="

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
apt-get update -qq
apt-get install -y -qq docker.io docker-compose-v2 git
systemctl enable docker && systemctl start docker
echo "[$(date)] Docker ready"

# --- Clone repo ---
cd /opt
git clone https://github.com/ffwd-org/stg-seats-poc.git
cd stg-seats-poc/poc-6-actor-model

# --- Build Docker image (more reliable than bare-metal Erlang install) ---
echo "[$(date)] Building Elixir Docker image..."
docker build -t stg-seats-elixir:poc .
echo "[$(date)] Docker image built"

# --- Start Elixir app with tuned BEAM ---
echo "[$(date)] Starting Elixir app..."
docker run -d --name elixir-poc --network=host \
  --ulimit nofile=1048576:1048576 \
  -e ERL_FLAGS="+S 8:8 +P 1000000" \
  stg-seats-elixir:poc
sleep 5

# Health check
echo "[$(date)] Waiting for health check..."
HEALTHY=""
for i in $(seq 1 30); do
  if curl -sf http://localhost:4000/health > /dev/null 2>&1; then
    HEALTHY="true"
    break
  fi
  sleep 2
done

if [ "$HEALTHY" = "true" ]; then
  echo "[$(date)] Elixir app running on :4000"
else
  echo "[$(date)] WARNING: health check failed, checking container..."
  docker logs elixir-poc 2>&1 | tail -20
fi

# Signal ready
gcloud compute instances add-metadata "$INSTANCE" --zone="$ZONE" --metadata=ready=true
echo "[$(date)] === Elixir service node READY ==="

# Keep alive — container runs in background
while true; do
  if ! docker ps --filter name=elixir-poc --format '{{.Status}}' | grep -q "Up"; then
    echo "[$(date)] WARNING: Elixir container stopped, restarting..."
    docker start elixir-poc 2>/dev/null || true
  fi
  sleep 30
done
