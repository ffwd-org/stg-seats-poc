#!/bin/bash
# provision-cluster-c.sh — Standalone (POC 6: Elixir/BEAM)
set -e

ZONE="${ZONE:-us-central1-a}"
PROJECT=$(gcloud config get-value project --quiet)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "[cluster-c] Provisioning in $ZONE (project: $PROJECT)..."

# Elixir/BEAM node
echo "[cluster-c] Creating Elixir node (c3-standard-8, SPOT)..."
gcloud compute instances create poc-elixir \
  --zone="$ZONE" \
  --machine-type=c3-standard-8 \
  --image-family=ubuntu-2404-lts-amd64 \
  --image-project=ubuntu-os-cloud \
  --boot-disk-size=50GB \
  --network-tier=PREMIUM \
  --provisioning-model=SPOT \
  --instance-termination-action=STOP \
  --tags=stg-seats-poc \
  --labels=poc=stg-seats,cluster=c \
  --scopes=compute-rw,storage-rw \
  --metadata-from-file=startup-script="$SCRIPT_DIR/startup-scripts/service-elixir.sh"

# Load generator
echo "[cluster-c] Creating loadgen node (c3-standard-4, SPOT)..."
gcloud compute instances create poc-loadgen-c \
  --zone="$ZONE" \
  --machine-type=c3-standard-4 \
  --image-family=ubuntu-2404-lts-amd64 \
  --image-project=ubuntu-os-cloud \
  --boot-disk-size=50GB \
  --network-tier=PREMIUM \
  --provisioning-model=SPOT \
  --instance-termination-action=STOP \
  --tags=stg-seats-poc \
  --labels=poc=stg-seats,cluster=c \
  --scopes=compute-rw,storage-rw \
  --metadata-from-file=startup-script="$SCRIPT_DIR/startup-scripts/loadgen-day4.sh"

LOADGEN_IP=$(gcloud compute instances describe poc-loadgen-c \
  --zone="$ZONE" --format='value(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null || echo "pending")

echo ""
echo "[cluster-c] Provisioned successfully."
echo "  Grafana: http://$LOADGEN_IP:3000"
echo "  Logs:    gcloud compute ssh poc-loadgen-c --zone=$ZONE -- tail -f /var/log/poc-startup.log"
