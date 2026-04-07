# POC 1 — Valkey Contention: HSET vs BITFIELD

**ADR:** ADR-002 (Hold Execution Flow), ADR-004 (Capacity Planning)
**Compare:** HSET (one hash field per seat) vs BITFIELD (2 bits per seat) for 100,000-seat events
**Daily infra cost:** GCP Spot ~$4.00 (2× c3-standard-8)

## Table of Contents

1. [Architecture](#architecture)
2. [GCP Provisioning](#gcp-provisioning)
3. [Valkey Setup](#valkey-setup)
4. [Running the Tests](#running-the-tests)
5. [Metrics & Dashboards](#metrics--dashboards)
6. [Interpretation Guide](#interpretation-guide)
7. [Teardown](#teardown)

---

## Architecture

### Infrastructure
```
poc-loadgen (c3-standard-8, Spot)     poc-valkey (c3-standard-8, Spot)
┌──────────────────────────────┐      ┌──────────────────────────────┐
│  Go load generator           │      │  Valkey 8                     │
│  Prometheus + Grafana        │ ←──→ │  valkey-exporter sidecar      │
│  tune-os.sh applied          │ TCP  │  maxmemory: 12GB             │
└──────────────────────────────┘      └──────────────────────────────┘
     ↑ SSH + metrics                      ↑ Internal VPC only
```

### Valkey Key Schemas
```
HSET mode:
  seats:event:1                    (hash)
    seat:00001 → "available"
    seat:00002 → "available"
    ...
    seat:100000 → "available"

BITFIELD mode:
  seats:event:1:bits              (string — 2 bits per seat = 25KB total)
    Bit 0-1:   seat 1 status     (00=available, 01=held, 10=booked, 11=reserved)
    Bit 2-3:   seat 2 status
    ...
    Bit 199998-199999: seat 100000 status

  seats:event:1:holders           (hash — needed for token → seat mapping)
    seatIdx → holderToken
```

---

## GCP Provisioning

### Prerequisites
```bash
# Authenticate
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
gcloud config set zone us-central1-a

# Enable required APIs
gcloud services enable compute.googleapis.com
```

### Provision Cluster A
```bash
cd infra/gcp

# Valkey node
gcloud compute instances create poc-valkey \
  --zone=us-central1-a \
  --machine-type=c3-standard-8 \
  --image-family=ubuntu-2404-lts-amd64 \
  --image-project=ubuntu-os-cloud \
  --network-tier=PREMIUM \
  --provisioning-model=SPOT \
  --instance-termination-action=STOP \
  --labels=poc=stg-seats,cluster=a,pocnum=1

# Load generator node
gcloud compute instances create poc-loadgen \
  --zone=us-central1-a \
  --machine-type=c3-standard-8 \
  --image-family=ubuntu-2404-lts-amd64 \
  --image-project=ubuntu-os-cloud \
  --network-tier=PREMIUM \
  --provisioning-model=SPOT \
  --instance-termination-action=STOP \
  --labels=poc=stg-seats,cluster=a,pocnum=1
```

### Get Internal IPs
```bash
VALKEY_IP=$(gcloud compute instances describe poc-valkey \
  --zone=us-central1-a \
  --format='get(networkInterfaces[0].networkIP)')

LOADGEN_IP=$(gcloud compute instances describe poc-loadgen \
  --zone=us-central1-a \
  --format='get(networkInterfaces[0].networkIP)')

echo "VALKEY_IP=$VALKEY_IP"
echo "LOADGEN_IP=$LOADGEN_IP"
```

### Apply OS Tuning (both nodes)
SSH to each node and run:
```bash
# On BOTH valkey and loadgen nodes
curl -sL https://raw.githubusercontent.com/ffwd-org/stg-seats-poc/main/infra/tune-os.sh | bash

# Verify
ulimit -n  # should show 1048576
```

### Firewall Rules
```bash
# Allow internal VPC traffic
gcloud compute firewall-rules create allow-internal \
  --allow=tcp,udp,icmp \
  --source-ranges=10.10.0.0/16 \
  --target-tags=poc-valkey,poc-loadgen

# Allow SSH from your IP only
gcloud compute firewall-rules create allow-ssh \
  --allow=tcp:22 \
  --source-ranges=YOUR_IP/32

# Allow Grafana (loadgen node only)
gcloud compute firewall-rules create allow-grafana \
  --allow=tcp:3000 \
  --target-tags=poc-loadgen
```

---

## Valkey Setup

SSH to the Valkey node and start Valkey:
```bash
# Start Valkey with 12GB memory limit
docker run -d \
  --name valkey \
  --restart unless-stopped \
  -p 6379:6379 \
  -v valkey-data:/data \
  valkey/valkey:8 \
  --maxmemory 12gb \
  --maxmemory-policy allkeys-lru \
  --save "" \
  --appendonly no

# Start Prometheus exporter sidecar
docker run -d \
  --name valkey-exporter \
  --restart unless-stopped \
  -p 9120:9120 \
  prometheus/valkey-exporter
```

Verify:
```bash
docker exec valkey valkey-cli ping
# PONG

docker exec valkey valkey-cli INFO memory | grep used_memory_human
# used_memory_human:2.00M  (empty, 100K HSET keys will be ~8-10MB)
```

---

## Running the Tests

All commands run from the `poc-1-valkey-contention/` directory on the loadgen node.

### 1. Build and Install Go (loadgen node)
```bash
# If Go is not installed
curl -sL https://go.dev/dl/go1.24.linux-amd64.tar.gz | sudo tar -C /usr/local -xzf -
export PATH=$PATH:/usr/local/go/bin

# Verify
go version
```

### 2. Seed Data (run on loadgen node)
```bash
export VALKEY_ADDR=<valkey-internal-ip>

# Seed HSET format (run first)
go run ./cmd/seed --mode=hset --seats=100000 --valkey-addr=$VALKEY_ADDR

# OR seed BITFIELD format (run separately)
go run ./cmd/seed --mode=bitfield --seats=100000 --valkey-addr=$VALKEY_ADDR

# OR seed both sequentially
go run ./cmd/seed --mode=both --seats=100000 --valkey-addr=$VALKEY_ADDR
```

### 3. Start Prometheus + Grafana (loadgen node)
```bash
cd infra
docker compose -f docker-compose.metrics.yml up -d

# Grafana available at http://<loadgen-ip>:3000 (no auth)
# Prometheus available at http://<loadgen-ip>:9090
```

Import dashboard: Grafana UI → Dashboards → Import → paste `grafana/dashboard.json`

### 4. Run Load Tests
```bash
export VALKEY_ADDR=<valkey-internal-ip>
mkdir -p results

# HSET ramp test
go run ./cmd/loadgen \
  --mode=hset \
  --valkey-addr=$VALKEY_ADDR \
  --ramp=100,1000,5000,10000,25000,50000,100000 \
  --stage-duration=60s \
  --cooldown=10s \
  --metrics-port=2112 \
  2>&1 | tee results/hset-run.log

# Flush and reseed BITFIELD
docker exec valkey valkey-cli FLUSHDB
go run ./cmd/seed --mode=bitfield --seats=100000 --valkey-addr=$VALKEY_ADDR

# BITFIELD ramp test
go run ./cmd/loadgen \
  --mode=bitfield \
  --valkey-addr=$VALKEY_ADDR \
  --ramp=100,1000,5000,10000,25000,50000,100000 \
  --stage-duration=60s \
  --cooldown=10s \
  --metrics-port=2112 \
  2>&1 | tee results/bitfield-run.log
```

### Ramp Stages
| Stage | Workers | Duration | Purpose |
|-------|---------|----------|---------|
| Warmup | 100 | 30s | Validate scripts, baseline |
| Ramp 1 | 1,000 | 60s | Baseline OPS |
| Ramp 2 | 5,000 | 60s | Early contention |
| Ramp 3 | 10,000 | 120s | Moderate load |
| Ramp 4 | 25,000 | 120s | Heavy contention |
| Ramp 5 | 50,000 | 120s | Near limits |
| Ramp 6 | 100,000 | 120s | Breaking point |

---

## Metrics & Dashboards

### Key Metrics
| Metric | Source | What it tells you |
|--------|--------|-------------------|
| `rate(poc_ops_total{result="ok"}[5s])` | loadgen | Successful ops/sec |
| `histogram_quantile(0.99, ...)` | loadgen | p99 hold latency |
| Valkey `used_memory_human` | valkey-exporter | Memory footprint |
| Valkey CPU % | valkey-exporter | Saturation point |
| Error rate | loadgen counter | Contention level |

### Grafana Dashboard
Import `grafana/dashboard.json` into Grafana. Panels:
1. **OPS/sec (HSET vs BITFIELD)** — primary comparison panel
2. **Cumulative ops** — total throughput
3. **Hold latency percentiles (p50/p95/p99)**
4. **Active workers** — load generator saturation
5. **Error rate %**
6. **Error rate (absolute)**

---

## Interpretation Guide

| Outcome | Condition | Action |
|---------|-----------|--------|
| **HSET is sufficient** | HSET sustains >150K OPS at p99 <10ms | Keep current HSET encoding |
| **BITFIELD wins clearly** | BITFIELD shows >2x OPS at same latency | Recommend BITFIELD migration |
| **Both hit wall early** | Either saturates <50K OPS | Intent queue (POC 4) is mandatory |
| **Memory matters** | BITFIELD uses <5% memory of HSET | Factor into capacity planning |

### Decision Threshold
If **HSET** achieves **≥150K successful ops/sec** at **p99 < 10ms** during Ramp 4-6 (25K-100K workers), it is sufficient — no migration needed.

---

## Teardown

```bash
# Delete GCP VMs
gcloud compute instances delete poc-valkey poc-loadgen \
  --zone=us-central1-a \
  --quiet

# Remove firewall rules
gcloud compute firewall-rules delete allow-internal allow-ssh allow-grafana --quiet
```

Or use the Makefile:
```bash
make teardown
```
