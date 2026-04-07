#!/bin/bash
# teardown-gcp.sh — Destroy all GCP POC infrastructure

set -e

echo "[teardown-gcp] Destroying all POC instances..."
gcloud compute instances list --filter="labels.poc=stg-seats" --format="value(name,zone)" | \
  while read NAME ZONE; do
    [ -n "$NAME" ] && gcloud compute instances delete "$NAME" --zone="$ZONE" --quiet
  done

echo "[teardown-gcp] All GCP POC infra destroyed."
