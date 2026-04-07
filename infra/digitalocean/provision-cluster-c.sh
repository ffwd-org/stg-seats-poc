#!/bin/bash
# provision-cluster-c.sh — Standalone (POC 6: Elixir/BEAM)
# Provisions: Elixir/BEAM node + Load generator

set -e

REGION="${REGION:-nyc1}"
TAG_NAMES="stg-seats-poc,cluster-c"

echo "[cluster-c] Starting provisioning in $REGION..."

VPC_ID=$(doctl vpcs list --format ID,Name --no-header | grep "$VPC_NAME" | awk '{print $1}')
if [ -z "$VPC_ID" ]; then
  echo "[cluster-c] VPC not found. Run provision-cluster-a.sh first."
  exit 1
fi

SSH_KEYS=$(doctl compute ssh-key list --format ID --no-header | tr '\n' ',')

# Elixir/BEAM node
echo "[cluster-c] Creating Elixir node..."
doctl compute droplet create poc-elixir \
  --region "$REGION" \
  --size c-8 \
  --image ubuntu-24-04-x64 \
  --vpc-uuid "$VPC_ID" \
  --ssh-keys "$SSH_KEYS" \
  --tag-names "$TAG_NAMES" \
  --wait

# Load generator
echo "[cluster-c] Creating load-gen node..."
doctl compute droplet create poc-loadgen-c \
  --region "$REGION" \
  --size c-8 \
  --image ubuntu-24-04-x64 \
  --vpc-uuid "$VPC_ID" \
  --ssh-keys "$SSH_KEYS" \
  --tag-names "$TAG_NAMES" \
  --wait

echo "[cluster-c] Cluster C provisioned successfully."
