# POC 3 — Go/Lua Dynamic Best Available Limits

**ADR:** ADR-003 (Go/Valkey Lua vs Pre-computed lists vs Elixir)
**Test:** Adjacent seat search in Valkey Lua under concurrent load, varying fragmentation
**Daily infra cost:** GCP Spot ~$4.00 (Cluster A — same VMs as POC 1)

> Reuses Cluster A from POC 1 — no additional infra cost when run on the same day.

## Architecture

```
Venue: 100,000 seats = 20 sections × 100 rows × 50 seats

Valkey keys:
  seats:event:1              HSET: seatId → status
  venue:event:1:layout        HSET: seatId → {section,row,index}
  venue:event:1:rows          HSET: "A-1" → "seat:00001,seat:00002,...,seat:00050"
```

### Fragmentation Modes
- `--fragmentation=0` — All seats available (empty map)
- `--fragmentation=25` — 25% randomly pre-held
- `--fragmentation=50` — 50% pre-held (mid-sale)
- `--fragmentation=80` — 80% pre-held (near sell-out)

## GCP Provisioning (Cluster A — same as POC 1)
```bash
# Valkey node
gcloud compute instances create poc-valkey \
  --zone=us-central1-a --machine-type=c3-standard-8 \
  --image-family=ubuntu-2404-lts-amd64 --image-project=ubuntu-os-cloud \
  --network-tier=PREMIUM --provisioning-model=SPOT \
  --instance-termination-action=STOP \
  --labels=poc=stg-seats,cluster=a,pocnum=3

# Load generator
gcloud compute instances create poc-loadgen \
  --zone=us-central1-a --machine-type=c3-standard-8 \
  --image-family=ubuntu-2404-lts-amd64 --image-project=ubuntu-os-cloud \
  --network-tier=PREMIUM --provisioning-model=SPOT \
  --instance-termination-action=STOP \
  --labels=poc=stg-seats,cluster=a,pocnum=3
```

### Start Valkey (on valkey node)
```bash
docker run -d --name valkey -p 6379:6379 \
  -v valkey-data:/data valkey/valkey:8 --maxmemory 12gb
```

## Running the Tests

### Seed venue + layout
```bash
export VALKEY_ADDR=<valkey-internal-ip>

# Empty map (baseline)
go run ./cmd/seed --mode=both --fragmentation=0 --valkey-addr=$VALKEY_ADDR

# Mid-sale (50% fragmented)
go run ./cmd/seed --mode=both --fragmentation=50 --valkey-addr=$VALKEY_ADDR
```

### Load Test — best-available vs random baseline
```bash
# Best-available algorithm
go run ./cmd/loadgen \
  --mode=best-available \
  --valkey-addr=$VALKEY_ADDR \
  --workers=1000 \
  --quantity=2 \
  --section=A \
  --stage-duration=60s \
  --metrics-port=2112

# Random baseline (no adjacency — for comparison)
go run ./cmd/loadgen \
  --mode=random \
  --valkey-addr=$VALKEY_ADDR \
  --workers=1000 \
  --quantity=2 \
  --stage-duration=60s
```

### Ramp Stages
| Workers | Duration | Fragmentation | Purpose |
|---------|----------|---------------|---------|
| 100 | 60s | 0% | Baseline latency |
| 500 | 60s | 0% | Light contention |
| 1,000 | 60s | 0% | Typical load |
| 1,000 | 60s | 50% | Mid-sale fragmentation |
| 1,000 | 60s | 80% | Near sell-out |
| 2,000 | 120s | 50% | Heavy contention |
| 5,000 | 120s | 50% | Breaking point |

## Metrics & Dashboards

Import `grafana/dashboard.json`. Key panels:
- **OPS/sec** — best-available search throughput
- **Latency p50/p95/p99** — critical at high fragmentation
- **Active workers** — loadgen saturation
- **Error rate** — "no contiguous block" failures at high fragmentation

## Interpretation Guide

| Outcome | Condition | Action |
|---------|-----------|--------|
| **Dynamic viable** | p99 <50ms at 1K workers, 50% fragmentation | Go/Lua is sufficient |
| **Pre-compute needed** | p99 degrades >200ms above 50% fragmentation | Pre-computed sorted lists (ADR-003) |
| **Elixir viable** | Fragmentation + contention both hit walls | POC 6 (Elixir/BEAM) becomes mandatory |

## Teardown
```bash
gcloud compute instances delete poc-valkey poc-loadgen \
  --zone=us-central1-a --quiet
```
