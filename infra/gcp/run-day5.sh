#!/bin/bash
# run-day5.sh — Day 5: Rerun missing POC data
#   Cluster A: POC 1 memory + POC 4 latency
#   Cluster B: POC 5 failure modes
#
# Both clusters run IN PARALLEL to minimize wall-clock time.
# Usage: ./run-day5.sh [--teardown]
set -e

ZONE="${ZONE:-us-central1-a}"
BUCKET="gs://stg-seats-poc-results"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Day 5: Missing Data Reruns ==="
echo ""

# ============================================================
# Provision both clusters in parallel
# ============================================================
echo "--- Provisioning Cluster A (Valkey + NATS) ---"

# Cluster A: Valkey service node
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
  --labels=poc=stg-seats,cluster=a,day=5 \
  --scopes=compute-rw,storage-rw \
  --metadata-from-file=startup-script="$SCRIPT_DIR/startup-scripts/service-valkey-day5.sh"

# Cluster A: Loadgen
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
  --labels=poc=stg-seats,cluster=a,day=5 \
  --scopes=compute-rw,storage-rw \
  --metadata-from-file=startup-script="$SCRIPT_DIR/startup-scripts/loadgen-day5a.sh"

echo ""
echo "--- Provisioning Cluster B (Centrifugo) ---"

# Cluster B: Centrifugo service node
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
  --labels=poc=stg-seats,cluster=b,day=5 \
  --scopes=compute-rw,storage-rw \
  --metadata-from-file=startup-script="$SCRIPT_DIR/startup-scripts/service-centrifugo-day5.sh"

# Cluster B: Loadgen (needs alias IP support for 250K connections)
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
  --labels=poc=stg-seats,cluster=b,day=5 \
  --scopes=compute-rw,storage-rw \
  --metadata-from-file=startup-script="$SCRIPT_DIR/startup-scripts/loadgen-day5b.sh"

echo ""
echo "=== All 4 VMs provisioning. Tests will start automatically. ==="

# Print access info
sleep 10
LOADGEN_A_IP=$(gcloud compute instances describe poc-loadgen \
  --zone="$ZONE" --format='value(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null || echo "pending")
LOADGEN_B_IP=$(gcloud compute instances describe poc-loadgen-b \
  --zone="$ZONE" --format='value(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null || echo "pending")

echo ""
echo "Cluster A (POC 1 + POC 4):"
echo "  Grafana: http://$LOADGEN_A_IP:3000"
echo "  Logs:    gcloud compute ssh poc-loadgen --zone=$ZONE -- tail -f /var/log/poc-startup.log"
echo ""
echo "Cluster B (POC 5):"
echo "  Grafana: http://$LOADGEN_B_IP:3000"
echo "  Logs:    gcloud compute ssh poc-loadgen-b --zone=$ZONE -- tail -f /var/log/poc-startup.log"
echo ""

# ============================================================
# Poll both clusters for completion
# ============================================================
echo "Polling for completion..."
START_TIME=$(date +%s)
CLUSTER_A_DONE=""
CLUSTER_B_DONE=""

while true; do
  if [ -z "$CLUSTER_A_DONE" ]; then
    STATUS_A=$(gcloud compute instances describe poc-loadgen \
      --zone="$ZONE" --format='value(metadata.items[done])' 2>/dev/null || echo "")
    if [ "$STATUS_A" = "true" ]; then
      CLUSTER_A_DONE="true"
      echo "  [$(date)] Cluster A (POC 1+4) COMPLETE"
    elif [ "$STATUS_A" = "error" ]; then
      echo "  [$(date)] Cluster A FAILED"
      CLUSTER_A_DONE="error"
    fi
  fi

  if [ -z "$CLUSTER_B_DONE" ]; then
    STATUS_B=$(gcloud compute instances describe poc-loadgen-b \
      --zone="$ZONE" --format='value(metadata.items[done])' 2>/dev/null || echo "")
    if [ "$STATUS_B" = "true" ]; then
      CLUSTER_B_DONE="true"
      echo "  [$(date)] Cluster B (POC 5) COMPLETE"
    elif [ "$STATUS_B" = "error" ]; then
      echo "  [$(date)] Cluster B FAILED"
      CLUSTER_B_DONE="error"
    fi
  fi

  if [ -n "$CLUSTER_A_DONE" ] && [ -n "$CLUSTER_B_DONE" ]; then
    ELAPSED=$(( ($(date +%s) - START_TIME) / 60 ))
    echo ""
    echo "=== Both clusters finished in ${ELAPSED} minutes ==="
    break
  fi

  ELAPSED=$(( ($(date +%s) - START_TIME) / 60 ))
  echo "  [${ELAPSED}m] A=${CLUSTER_A_DONE:-running} B=${CLUSTER_B_DONE:-running}"
  sleep 60
done

# ============================================================
# Download results
# ============================================================
mkdir -p ./results/day5
gsutil -m cp -r "$BUCKET/day5a/" ./results/day5/ 2>&1 | tail -5
gsutil -m cp -r "$BUCKET/day5b/" ./results/day5/ 2>&1 | tail -5
echo "Results in ./results/day5/"

# ============================================================
# Teardown
# ============================================================
echo ""
if [ "${1:-}" = "--teardown" ]; then
  "$SCRIPT_DIR/teardown-gcp.sh"
else
  echo "VMs still running. Tear down manually:"
  echo "  $SCRIPT_DIR/teardown-gcp.sh"
fi

echo "=== Day 5 complete ==="
