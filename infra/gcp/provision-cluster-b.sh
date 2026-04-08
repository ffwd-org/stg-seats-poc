#!/bin/bash
# provision-cluster-b.sh — Connection-heavy (POC 2, 5)
set -e

ZONE="${ZONE:-us-central1-a}"
PROJECT=$(gcloud config get-value project --quiet)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "[cluster-b] Provisioning in $ZONE (project: $PROJECT)..."

# App server (memory-optimized for 250K WebSocket connections)
echo "[cluster-b] Creating app server (m3-standard-8, 64GB RAM, SPOT)..."
gcloud compute instances create poc-appserver \
  --zone="$ZONE" \
  --machine-type=c3-highmem-8 \
  --image-family=ubuntu-2404-lts-amd64 \
  --image-project=ubuntu-os-cloud \
  --boot-disk-size=50GB \
  --network-tier=PREMIUM \
  --provisioning-model=SPOT \
  --instance-termination-action=STOP \
  --tags=stg-seats-poc \
  --labels=poc=stg-seats,cluster=b \
  --scopes=compute-rw,storage-rw \
  --metadata-from-file=startup-script="$SCRIPT_DIR/startup-scripts/service-wsserver.sh"

# Load generator
echo "[cluster-b] Creating loadgen node (c3-standard-8, SPOT)..."
gcloud compute instances create poc-loadgen-b \
  --zone="$ZONE" \
  --machine-type=c3-standard-8 \
  --image-family=ubuntu-2404-lts-amd64 \
  --image-project=ubuntu-os-cloud \
  --boot-disk-size=50GB \
  --network-tier=PREMIUM \
  --provisioning-model=SPOT \
  --instance-termination-action=STOP \
  --tags=stg-seats-poc \
  --labels=poc=stg-seats,cluster=b \
  --scopes=compute-rw,storage-rw \
  --metadata-from-file=startup-script="$SCRIPT_DIR/startup-scripts/loadgen-day3.sh"

LOADGEN_IP=$(gcloud compute instances describe poc-loadgen-b \
  --zone="$ZONE" --format='value(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null || echo "pending")

echo ""
echo "[cluster-b] Provisioned successfully."
echo "  Grafana: http://$LOADGEN_IP:3000"
echo "  Logs:    gcloud compute ssh poc-loadgen-b --zone=$ZONE -- tail -f /var/log/poc-startup.log"
