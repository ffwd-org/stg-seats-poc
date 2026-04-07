#!/bin/bash
# provision-cluster-b-gcp.sh — Connection-heavy (POC 2, 5)

set -e

ZONE="${ZONE:-us-central1-a}"

echo "[cluster-b-gcp] Provisioning in $ZONE..."

# App server (memory-optimized for 250K WebSocket connections)
gcloud compute instances create poc-appserver \
  --zone="$ZONE" \
  --machine-type=m3-standard-8 \
  --image-family=ubuntu-2404-lts-amd64 \
  --image-project=ubuntu-os-cloud \
  --network-tier=PREMIUM \
  --provisioning-model=SPOT \
  --instance-termination-action=STOP \
  --labels=poc=stg-seats,cluster=b

# Load generator
gcloud compute instances create poc-loadgen-b \
  --zone="$ZONE" \
  --machine-type=c3-standard-8 \
  --image-family=ubuntu-2404-lts-amd64 \
  --image-project=ubuntu-os-cloud \
  --network-tier=PREMIUM \
  --provisioning-model=SPOT \
  --instance-termination-action=STOP \
  --labels=poc=stg-seats,cluster=b

echo "[cluster-b-gcp] Done."
