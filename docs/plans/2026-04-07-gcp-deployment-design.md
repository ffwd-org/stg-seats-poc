# GCP Deployment Design — stg-seats POC Load Tests

> **Date**: 2026-04-07
> **Project**: `silicon-pointer-490721-r0` (paytix-ctgot)
> **Zone**: `us-central1-a`
> **Approach**: Fully automated — VMs self-provision, run tests, upload results, signal done

---

## Overview

6 POCs run across 3 GCP clusters over 4 days. Each cluster is fully autonomous: VMs boot with startup scripts that install dependencies, clone the repo, run tests, upload results to a GCS bucket, and signal completion. A local orchestrator script provisions VMs, polls for completion, downloads results, and tears down.

No SSH required. Optional Grafana live view via external IP.

---

## One-Time Project Setup

Run once before any cluster provisioning:

```bash
# Enable Compute API
gcloud services enable compute.googleapis.com

# Create results bucket
gcloud storage buckets create gs://stg-seats-poc-results \
  --location=us-central1 --uniform-bucket-level-access

# Firewall: internal traffic between POC VMs
gcloud compute firewall-rules create poc-allow-internal \
  --direction=INGRESS \
  --action=ALLOW \
  --rules=tcp:0-65535,udp:0-65535,icmp \
  --source-tags=stg-seats-poc \
  --target-tags=stg-seats-poc

# Firewall: SSH from your IP
gcloud compute firewall-rules create poc-allow-ssh \
  --direction=INGRESS \
  --action=ALLOW \
  --rules=tcp:22 \
  --source-ranges=<YOUR_IP>/32 \
  --target-tags=stg-seats-poc

# Firewall: Grafana access (port 3000) from your IP
gcloud compute firewall-rules create poc-allow-grafana \
  --direction=INGRESS \
  --action=ALLOW \
  --rules=tcp:3000 \
  --source-ranges=<YOUR_IP>/32 \
  --target-tags=stg-seats-poc
```

---

## Architecture

### Two VM Roles

Every cluster has two roles:

**Service Node** (Valkey / Centrifugo / Elixir):
1. OS tuning (nofile 1M, TCP stack, swap off)
2. Install Docker
3. Start the service (Valkey, WS server, Elixir app)
4. Start exporter sidecar (Prometheus metrics)
5. Set instance metadata `ready=true`

**Loadgen Node** (orchestrator + load generator):
1. OS tuning
2. Install Go 1.24 + Docker
3. Clone `ffwd-org/stg-seats-poc`, build POC binaries
4. Start Prometheus + Grafana (docker compose)
5. Poll until service node metadata `ready=true`
6. Discover service node internal IP via `gcloud compute instances describe`
7. Run all POCs for this cluster sequentially
8. Upload `results/` to `gs://stg-seats-poc-results/<cluster>/`
9. Set instance metadata `done=true`

### VM-to-VM Discovery

The loadgen discovers the service node IP at runtime:

```bash
SERVICE_IP=$(gcloud compute instances describe poc-valkey \
  --zone=us-central1-a \
  --format='value(networkInterfaces[0].networkIP)')
```

This internal IP is passed as `--valkey-addr=$SERVICE_IP:6379` to test commands.

---

## Cluster Definitions

### Cluster A — Valkey-centric (Day 1 + Day 2)

| Role | VM Name | Machine Type | Purpose |
|------|---------|-------------|---------|
| Service | `poc-valkey` | `c3-standard-8` (8 vCPU, 32GB) | Valkey 8 + exporter |
| Loadgen | `poc-loadgen` | `c3-standard-8` (8 vCPU, 32GB) | Go load generators |

**Day 1 POCs**: POC 1 (HSET vs BITFIELD) → POC 3 (Best Available)
**Day 2 POCs**: POC 4 (Intent Queue — adds queue broker container on loadgen)

**Service node startup:**
- Docker + Valkey 8 container on port 6379
- Valkey exporter on port 9121

**Loadgen Day 1 sequence:**
1. Build `poc-1-valkey-contention` and `poc-3-best-available`
2. POC 1: `make seed && make run-hset && make run-bitfield`
3. POC 3: `make seed-f0 && make seed-f50 && make seed-f80` (each followed by test run)
4. Upload results

**Loadgen Day 2 sequence:**
1. Start Redpanda container, NATS container (for POC 4 queue comparison)
2. Build `poc-4-intent-queue`
3. POC 4: `make direct && make redpanda && make nats && make valkey-streams`
4. Upload results

### Cluster B — Connection-heavy (Day 3)

| Role | VM Name | Machine Type | Purpose |
|------|---------|-------------|---------|
| Service | `poc-appserver` | `m3-standard-8` (8 vCPU, 64GB) | Go WS server → Centrifugo |
| Loadgen | `poc-loadgen-b` | `c3-standard-8` (8 vCPU, 32GB) | 250K connection generator |

**Day 3 POCs**: POC 2 (Go WebSocket) → POC 5 (Centrifugo)

Memory-optimized VM for the app server — 250K WebSocket connections consume 15-40GB RAM.

**Service node startup (Phase 1 — POC 2):**
- Install Go 1.24, clone repo
- Build and run `poc-2-websocket-fanout/cmd/wsserver`
- Set metadata `ready=true`

**Service node transition (Phase 2 — POC 5):**
- Stop Go WS server
- Start Centrifugo v5 container
- Set metadata `ready-poc5=true`

**Loadgen sequence:**
1. POC 2: ramp connections 10K→250K, broadcast tests
2. Signal service node to swap to Centrifugo (via metadata)
3. POC 5: same connection ramp + broadcast tests against Centrifugo
4. Upload results (includes side-by-side comparison)

### Cluster C — Standalone (Day 4)

| Role | VM Name | Machine Type | Purpose |
|------|---------|-------------|---------|
| Service | `poc-elixir` | `c3-standard-8` (8 vCPU, 32GB) | Elixir/BEAM app |
| Loadgen | `poc-loadgen-c` | `c3-standard-4` (4 vCPU, 16GB) | Go HTTP load generator |

**Day 4 POC**: POC 6 (Actor Model Engine)

**Service node startup:**
- Install Erlang/OTP 27 + Elixir 1.17
- Clone repo, `mix deps.get && mix compile`
- Run Elixir app on port 4000
- Set metadata `ready=true`

**Loadgen sequence:**
1. Build Go load generator
2. Seed venue via `POST /seed`
3. Run fragmentation + concurrency test phases
4. Upload results

---

## Local Orchestrator Scripts

Four scripts, one per day:

### run-day1.sh (Cluster A: POC 1 + POC 3)

```bash
#!/bin/bash
set -e
ZONE=us-central1-a
BUCKET=gs://stg-seats-poc-results

./infra/gcp/provision-cluster-a.sh

# Print Grafana URL
LOADGEN_IP=$(gcloud compute instances describe poc-loadgen \
  --zone=$ZONE --format='value(networkInterfaces[0].accessConfigs[0].natIP)')
echo "Grafana: http://$LOADGEN_IP:3000"

# Poll for completion
while true; do
  STATUS=$(gcloud compute instances describe poc-loadgen \
    --zone=$ZONE --format='value(metadata.items[done])' 2>/dev/null)
  [ "$STATUS" = "true" ] && break
  sleep 60
done

gsutil -m cp -r $BUCKET/cluster-a-day1/ ./results/cluster-a-day1/
echo "Day 1 done. Results in ./results/cluster-a-day1/"
```

### run-day2.sh (Cluster A: POC 4)

Same VMs (reuse or re-provision). Loadgen runs POC 4 sequence.

### run-day3.sh (Cluster B: POC 2 + POC 5)

Provisions `poc-appserver` (m3-standard-8) + `poc-loadgen-b`. Same poll/download pattern.

### run-day4.sh (Cluster C: POC 6)

Provisions `poc-elixir` + `poc-loadgen-c`. Same poll/download pattern.

### Teardown

After each day (or after all 4 days):
```bash
./infra/gcp/teardown-gcp.sh
```
Deletes all VMs with label `poc=stg-seats`.

---

## Results Storage

```
gs://stg-seats-poc-results/
├── cluster-a-day1/
│   ├── poc-1/
│   │   ├── hset-run.csv
│   │   ├── bitfield-run.csv
│   │   └── grafana-snapshot.json
│   └── poc-3/
│       ├── phase-a-fragmentation.csv
│       ├── phase-b-concurrency.csv
│       └── grafana-snapshot.json
├── cluster-a-day2/
│   └── poc-4/
│       ├── phase-a-throughput.csv
│       ├── phase-b-e2e.csv
│       ├── phase-c-burst.csv
│       └── grafana-snapshot.json
├── cluster-b/
│   ├── poc-2/
│   └── poc-5/
│       └── comparison-with-poc2.csv
└── cluster-c/
    └── poc-6/
        └── comparison-with-poc3.csv
```

---

## Cost Estimate (GCP Spot)

| Day | Cluster | VMs | Est. Runtime | Est. Cost |
|-----|---------|-----|-------------|-----------|
| 1 | A | 2x c3-standard-8 | ~3 hrs | ~$1.50 |
| 2 | A | 2x c3-standard-8 | ~3 hrs | ~$1.50 |
| 3 | B | m3-standard-8 + c3-standard-8 | ~4 hrs | ~$2.50 |
| 4 | C | c3-standard-8 + c3-standard-4 | ~3 hrs | ~$1.00 |
| **Total** | | | | **~$6.50** |

Spot VMs can be preempted. If that happens: re-run the day script (tests restart from scratch — each run is idempotent).

---

## Execution Schedule

| Day | Cluster | POCs | Estimated Duration |
|-----|---------|------|--------------------|
| Day 1 | A | POC 1 → POC 3 | ~3 hours |
| Day 2 | A | POC 4 | ~3 hours |
| Day 3 | B | POC 2 → POC 5 | ~4 hours |
| Day 4 | C | POC 6 | ~3 hours |

After Day 4: compile results into ADR-001 through ADR-004.
