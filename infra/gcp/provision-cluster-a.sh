#!/bin/bash
# provision-cluster-a-gcp.sh — Valkey-centric (POC 1, 3, 4)

set -e

ZONE="${ZONE:-us-central1-a}"
PROJECT=$(gcloud config get-value project --quiet)

echo "[cluster-a-gcp] Provisioning in $ZONE..."

# Valkey node
gcloud compute instances create poc-valkey \
  --zone="$ZONE" \
  --machine-type=c3-standard-8 \
  --image-family=ubuntu-2404-lts-amd64 \
  --image-project=ubuntu-os-cloud \
  --network-tier=PREMIUM \
  --provisioning-model=SPOT \
  --instance-termination-action=STOP \
  --labels=poc=stg-seats,cluster=a

# Load generator
gcloud compute instances create poc-loadgen \
  --zone="$ZONE" \
  --machine-type=c3-standard-8 \
  --image-family=ubuntu-2404-lts-amd64 \
  --image-project=ubuntu-os-cloud \
  --network-tier=PREMIUM \
  --provisioning-model=SPOT \
  --instance-termination-action=STOP \
  --labels=poc=stg-seats,cluster=a

echo "[cluster-a-gcp] Done."
