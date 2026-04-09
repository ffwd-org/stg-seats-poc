#!/bin/bash
# startup-script for Valkey + NATS service node — Day 5 (Cluster A rerun)
# Same as Day 1/2 service-valkey.sh but also starts NATS for POC 4 latency tests
#
# Day 2/3 lessons applied:
#   - set -uo (no -e)
#   - NATS started alongside Valkey for POC 4 rerun
set -uo pipefail
exec > >(tee /var/log/poc-startup.log) 2>&1

ZONE=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/zone | awk -F/ '{print $NF}')
INSTANCE=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/name)

echo "[$(date)] === Day 5: Valkey + NATS service node startup ==="

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
apt-get install -y -qq docker.io docker-compose-v2
systemctl enable docker && systemctl start docker
echo "[$(date)] Docker ready"

# --- Run Valkey 8 ---
docker rm -f valkey valkey-exporter 2>/dev/null || true

docker run -d --name valkey \
  --restart=unless-stopped \
  --network=host \
  --ulimit nofile=1048576:1048576 \
  valkey/valkey:8.0 \
  valkey-server --maxmemory 24gb --maxmemory-policy noeviction --save "" --appendonly no

echo "[$(date)] Waiting for Valkey to be ready..."
for i in $(seq 1 30); do
  docker exec valkey valkey-cli ping 2>/dev/null | grep -q PONG && break
  sleep 1
done
echo "[$(date)] Valkey ready"

# --- Run Valkey Exporter ---
docker run -d --name valkey-exporter \
  --restart=unless-stopped \
  --network=host \
  oliver006/redis_exporter:v1.66.0 \
  --redis.addr=localhost:6379
echo "[$(date)] Valkey exporter running on :9121"

# --- Run NATS with JetStream (for POC 4 latency rerun) ---
docker run -d --name nats-poc4 \
  --restart=unless-stopped \
  --network=host \
  nats:2.10 -js
sleep 3
echo "[$(date)] NATS JetStream running on :4222"

# --- Signal ready ---
gcloud compute instances add-metadata "$INSTANCE" --zone="$ZONE" --metadata=ready=true
echo "[$(date)] === Valkey + NATS service node READY ==="
