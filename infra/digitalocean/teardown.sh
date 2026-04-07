#!/bin/bash
# teardown.sh — Destroy all stg-seats-poc infrastructure

set -e

echo "[teardown] Destroying all POC droplets..."
doctl compute droplet delete --tag-name stg-seats-poc --force

echo "[teardown] Destroying VPC..."
VPC_ID=$(doctl vpcs list --format ID,Name --no-header | grep "stg-seats-poc" | awk '{print $1}')
if [ -n "$VPC_ID" ]; then
  doctl vpcs delete "$VPC_ID" --force
fi

echo "[teardown] All POC infra destroyed."
