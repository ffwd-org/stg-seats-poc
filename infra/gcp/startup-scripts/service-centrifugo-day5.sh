#!/bin/bash
# startup-script for Centrifugo service node — Day 5 (Cluster B: POC 5 failure modes)
#
# Day 3 lessons applied:
#   - set -uo (no -e)
#   - --network=host (no bridge NAT for 250K connections)
#   - api_insecure: true + internal_port 9000 for API
set -uo pipefail
exec > >(tee /var/log/poc-startup.log) 2>&1

ZONE=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/zone | awk -F/ '{print $NF}')
INSTANCE=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/name)

echo "[$(date)] === Day 5: Centrifugo service node startup ==="

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

# --- Clone repo for Centrifugo config ---
cd /opt
git clone https://github.com/ffwd-org/stg-seats-poc.git
cd stg-seats-poc/poc-5-edge-offload

# --- Write Centrifugo config ---
cat > /opt/centrifugo-config.json <<'CFGEOF'
{
  "token_hmac_secret_key": "poc-secret-key-for-jwt",
  "api_key": "poc-api-key",
  "api_insecure": true,
  "admin": false,
  "prometheus": true,
  "address": "0.0.0.0",
  "port": 8000,
  "internal_port": 9000,
  "namespaces": [
    {
      "name": "events",
      "history_size": 0,
      "history_ttl": "0s",
      "force_push_join_leave": false,
      "allow_subscribe_for_client": true
    }
  ],
  "client_channel_limit": 1,
  "client_queue_max_size": 1048576,
  "websocket": {
    "read_buffer_size": 512,
    "write_buffer_size": 512
  }
}
CFGEOF

# --- Start Centrifugo ---
docker rm -f centrifugo 2>/dev/null || true
docker run -d --name centrifugo \
  --restart=unless-stopped \
  --network=host \
  --ulimit nofile=1048576:1048576 \
  -v /opt/centrifugo-config.json:/centrifugo/config.json \
  centrifugo/centrifugo:v5 \
  centrifugo -c /centrifugo/config.json

sleep 3

# Health check
HEALTHY=""
for i in $(seq 1 30); do
  if curl -sf http://localhost:8000/health > /dev/null 2>&1; then
    HEALTHY="true"
    break
  fi
  sleep 2
done

if [ "$HEALTHY" = "true" ]; then
  echo "[$(date)] Centrifugo running on :8000 (API on :9000)"
else
  echo "[$(date)] WARNING: Centrifugo health check failed"
  docker logs centrifugo 2>&1 | tail -20
fi

# --- Signal ready ---
gcloud compute instances add-metadata "$INSTANCE" --zone="$ZONE" --metadata=ready=true
echo "[$(date)] === Centrifugo service node READY ==="
