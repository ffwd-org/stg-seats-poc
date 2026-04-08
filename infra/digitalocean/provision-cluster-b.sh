#!/bin/bash
# provision-cluster-b.sh — Connection-heavy (POC 2, 5)
# Provisions: Go WS server (memory-optimized) + Load generator

set -e

REGION="${REGION:-nyc1}"
VPC_NAME="stg-seats-poc"
TAG_NAMES="stg-seats-poc,cluster-b"

echo "[cluster-b] Starting provisioning in $REGION..."

# Reuse existing VPC
VPC_ID=$(doctl vpcs list --format ID,Name --no-header | grep "$VPC_NAME" | awk '{print $1}')
if [ -z "$VPC_ID" ]; then
  echo "[cluster-b] VPC not found. Run provision-cluster-a.sh first."
  exit 1
fi

SSH_KEYS=$(doctl compute ssh-key list --format ID --no-header | tr '\n' ',')

# App server (memory-optimized for 250K WebSocket connections)
echo "[cluster-b] Creating app server (m-8vcpu-64gb)..."
doctl compute droplet create poc-appserver \
  --region "$REGION" \
  --size m-8vcpu-64gb \
  --image ubuntu-24-04-x64 \
  --vpc-uuid "$VPC_ID" \
  --ssh-keys "$SSH_KEYS" \
  --tag-names "$TAG_NAMES" \
  --wait

# Load generator
echo "[cluster-b] Creating load-gen node..."
doctl compute droplet create poc-loadgen-b \
  --region "$REGION" \
  --size c-16 \
  --image ubuntu-24-04-x64 \
  --vpc-uuid "$VPC_ID" \
  --ssh-keys "$SSH_KEYS" \
  --tag-names "$TAG_NAMES" \
  --wait

echo "[cluster-b] Cluster B provisioned successfully."
