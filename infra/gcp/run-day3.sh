#!/bin/bash
# run-day3.sh — Cluster B: POC 2 (Go WebSocket) + POC 5 (Centrifugo)
set -e

ZONE="${ZONE:-us-central1-a}"
BUCKET="gs://stg-seats-poc-results"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Day 3: Cluster B (POC 2 + POC 5) ==="
echo ""

"$SCRIPT_DIR/provision-cluster-b.sh"

echo ""
echo "=== VMs provisioning. Tests will start automatically. ==="
echo ""

sleep 10
LOADGEN_IP=$(gcloud compute instances describe poc-loadgen-b \
  --zone="$ZONE" --format='value(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null)
echo "Grafana: http://$LOADGEN_IP:3000"
echo "Tail logs: gcloud compute ssh poc-loadgen-b --zone=$ZONE -- tail -f /var/log/poc-startup.log"
echo ""

echo "Polling for completion..."
START_TIME=$(date +%s)
while true; do
  STATUS=$(gcloud compute instances describe poc-loadgen-b \
    --zone="$ZONE" --format='value(metadata.items[done])' 2>/dev/null || echo "")
  if [ "$STATUS" = "true" ]; then
    ELAPSED=$(( ($(date +%s) - START_TIME) / 60 ))
    echo ""
    echo "=== Tests completed in ${ELAPSED} minutes ==="
    break
  elif [ "$STATUS" = "error" ]; then
    echo "=== Tests FAILED ==="
    exit 1
  fi
  ELAPSED=$(( ($(date +%s) - START_TIME) / 60 ))
  echo "  [${ELAPSED}m] still running..."
  sleep 60
done

mkdir -p ./results/day3
gsutil -m cp -r "$BUCKET/cluster-b/" ./results/day3/ 2>&1 | tail -5
echo "Results in ./results/day3/"

echo ""
read -p "Tear down Cluster B VMs? [y/N] " -n 1 -r
echo ""
[[ $REPLY =~ ^[Yy]$ ]] && "$SCRIPT_DIR/teardown-gcp.sh"

echo "=== Day 3 complete ==="
