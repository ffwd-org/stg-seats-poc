#!/bin/bash
# provision-cluster-a.sh — Valkey-centric (POC 1, 3, 4)
# Provisions: Valkey node + Load generator + optional Queue broker

set -e

REGION="${REGION:-nyc1}"
VPC_NAME="stg-seats-poc"
VPC_CIDR="10.10.10.0/24"
TAG_NAMES="stg-seats-poc,cluster-a"

echo "[cluster-a] Starting provisioning in $REGION..."

# Create VPC
VPC_ID=$(doctl vpcs create \
  --name "$VPC_NAME" \
  --region "$REGION" \
  --ip-range "$VPC_CIDR" \
  --output json | jq -r '.[0].id')

echo "[cluster-a] VPC created: $VPC_ID"

# Get SSH keys
SSH_KEYS=$(doctl compute ssh-key list --format ID --no-header | tr '\n' ',')

# Valkey node
echo "[cluster-a] Creating Valkey node..."
doctl compute droplet create poc-valkey \
  --region "$REGION" \
  --size c-8 \
  --image ubuntu-24-04-x64 \
  --vpc-uuid "$VPC_ID" \
  --ssh-keys "$SSH_KEYS" \
  --tag-names "$TAG_NAMES" \
  --wait

# Load generator
echo "[cluster-a] Creating load-gen node..."
doctl compute droplet create poc-loadgen \
  --region "$REGION" \
  --size c-16 \
  --image ubuntu-24-04-x64 \
  --vpc-uuid "$VPC_ID" \
  --ssh-keys "$SSH_KEYS" \
  --tag-names "$TAG_NAMES" \
  --wait

echo "[cluster-a] Cluster A provisioned successfully."
echo "  Valkey node: poc-valkey"
echo "  Load-gen:    poc-loadgen"
echo "  VPC:         $VPC_ID ($VPC_CIDR)"
