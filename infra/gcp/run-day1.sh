#!/bin/bash
# run-day1.sh — Cluster A: POC 1 (Valkey Contention) + POC 3 (Best Available)
# Provisions VMs, polls for completion, downloads results, optionally tears down.
set -e

ZONE="${ZONE:-us-central1-a}"
BUCKET="gs://stg-seats-poc-results"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Day 1: Cluster A (POC 1 + POC 3) ==="
echo ""

# --- Provision ---
"$SCRIPT_DIR/provision-cluster-a.sh" day1

echo ""
echo "=== VMs provisioning. Tests will start automatically. ==="
echo ""

# --- Wait for loadgen external IP ---
sleep 10
LOADGEN_IP=$(gcloud compute instances describe poc-loadgen \
  --zone="$ZONE" --format='value(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null)
echo "Grafana (live after ~5 min): http://$LOADGEN_IP:3000"
echo "Tail logs: gcloud compute ssh poc-loadgen --zone=$ZONE -- tail -f /var/log/poc-startup.log"
echo ""

# --- Poll for completion ---
echo "Polling for completion (checks every 60s)..."
START_TIME=$(date +%s)
while true; do
  STATUS=$(gcloud compute instances describe poc-loadgen \
    --zone="$ZONE" --format='value(metadata.items[done])' 2>/dev/null || echo "")

  if [ "$STATUS" = "true" ]; then
    ELAPSED=$(( ($(date +%s) - START_TIME) / 60 ))
    echo ""
    echo "=== Tests completed in ${ELAPSED} minutes ==="
    break
  elif [ "$STATUS" = "error" ]; then
    echo ""
    echo "=== Tests FAILED. Check logs: ==="
    echo "  gcloud compute ssh poc-loadgen --zone=$ZONE -- tail -100 /var/log/poc-startup.log"
    exit 1
  fi

  ELAPSED=$(( ($(date +%s) - START_TIME) / 60 ))
  echo "  [${ELAPSED}m] still running..."
  sleep 60
done

# --- Download results ---
echo ""
echo "Downloading results..."
mkdir -p ./results/day1
gsutil -m cp -r "$BUCKET/cluster-a-day1/" ./results/day1/ 2>&1 | tail -5
echo "Results saved to ./results/day1/"

# --- Teardown prompt ---
echo ""
read -p "Tear down Cluster A VMs? [y/N] " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
  "$SCRIPT_DIR/teardown-gcp.sh"
  echo "VMs destroyed."
else
  echo "VMs kept running. Tear down later with: $SCRIPT_DIR/teardown-gcp.sh"
fi

echo ""
echo "=== Day 1 complete ==="
