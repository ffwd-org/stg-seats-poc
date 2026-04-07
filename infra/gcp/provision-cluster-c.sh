#!/bin/bash
# provision-cluster-c-gcp.sh — Standalone (POC 6: Elixir/BEAM)

set -e

ZONE="${ZONE:-us-central1-a}"

echo "[cluster-c-gcp] Provisioning in $ZONE..."

# Elixir/BEAM node
gcloud compute instances create poc-elixir \
  --zone="$ZONE" \
  --machine-type=c3-standard-8 \
  --image-family=ubuntu-2404-lts-amd64 \
  --image-project=ubuntu-os-cloud \
  --network-tier=PREMIUM \
  --provisioning-model=SPOT \
  --instance-termination-action=STOP \
  --labels=poc=stg-seats,cluster=c

# Load generator
gcloud compute instances create poc-loadgen-c \
  --zone="$ZONE" \
  --machine-type=c3-standard-4 \
  --image-family=ubuntu-2404-lts-amd64 \
  --image-project=ubuntu-os-cloud \
  --network-tier=PREMIUM \
  --provisioning-model=SPOT \
  --instance-termination-action=STOP \
  --labels=poc=stg-seats,cluster=c

echo "[cluster-c-gcp] Done."
