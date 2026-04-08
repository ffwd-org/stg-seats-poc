#!/bin/bash
# provision-cluster-a.sh — Valkey-centric (POC 1, 3, 4)
# Usage: ./provision-cluster-a.sh [day1|day2]
set -e

ZONE="${ZONE:-us-central1-a}"
PROJECT=$(gcloud config get-value project --quiet)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DAY="${1:-day1}"

echo "[cluster-a] Provisioning in $ZONE (project: $PROJECT) for $DAY..."

# Valkey service node
echo "[cluster-a] Creating Valkey node (c3-standard-8, SPOT)..."
gcloud compute instances create poc-valkey \
  --zone="$ZONE" \
  --machine-type=c3-standard-8 \
  --image-family=ubuntu-2404-lts-amd64 \
  --image-project=ubuntu-os-cloud \
  --boot-disk-size=50GB \
  --network-tier=PREMIUM \
  --provisioning-model=SPOT \
  --instance-termination-action=STOP \
  --tags=stg-seats-poc \
  --labels=poc=stg-seats,cluster=a \
  --scopes=compute-rw,storage-rw \
  --metadata-from-file=startup-script="$SCRIPT_DIR/startup-scripts/service-valkey.sh"

# Loadgen node
LOADGEN_SCRIPT="$SCRIPT_DIR/startup-scripts/loadgen-${DAY}.sh"
if [ ! -f "$LOADGEN_SCRIPT" ]; then
  echo "[cluster-a] ERROR: $LOADGEN_SCRIPT not found"
  exit 1
fi

echo "[cluster-a] Creating loadgen node (c3-standard-8, SPOT) with $DAY script..."
gcloud compute instances create poc-loadgen \
  --zone="$ZONE" \
  --machine-type=c3-standard-8 \
  --image-family=ubuntu-2404-lts-amd64 \
  --image-project=ubuntu-os-cloud \
  --boot-disk-size=50GB \
  --network-tier=PREMIUM \
  --provisioning-model=SPOT \
  --instance-termination-action=STOP \
  --tags=stg-seats-poc \
  --labels=poc=stg-seats,cluster=a \
  --scopes=compute-rw,storage-rw \
  --metadata-from-file=startup-script="$LOADGEN_SCRIPT"

# Print info
LOADGEN_IP=$(gcloud compute instances describe poc-loadgen \
  --zone="$ZONE" --format='value(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null || echo "pending")

echo ""
echo "[cluster-a] Provisioned successfully."
echo "  Grafana: http://$LOADGEN_IP:3000 (available after ~5 min)"
echo "  SSH:     gcloud compute ssh poc-loadgen --zone=$ZONE"
echo "  Logs:    gcloud compute ssh poc-loadgen --zone=$ZONE -- tail -f /var/log/poc-startup.log"
echo "  Status:  gcloud compute instances describe poc-loadgen --zone=$ZONE --format='value(metadata.items[done])'"
