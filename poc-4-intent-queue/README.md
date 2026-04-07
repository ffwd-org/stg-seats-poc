# POC 4 — Intent Queue: Redpanda vs NATS vs Valkey Streams

**ADR:** ADR-002 (Hold Execution Flow)
**Test:** Direct REST-to-Valkey vs async queue (Redpanda, NATS JetStream, Valkey Streams)
**Daily infra cost:** GCP Spot ~$5.00 (Cluster A + c3-standard-4 queue broker)

> Add queue broker VM to Cluster A from POC 1. Can reuse same valkey + loadgen VMs.

## Architecture

```
Producer ───────────────────────────────────────────────────────────────
  │                                                                  │
  ├─ Direct: HTTP POST /hold ──────→ Valkey (hold_seat.lua)         │
  ├─ Redpanda: XADD seat-holds ──→ Redpanda ──→ Consumer ──→ Valkey │
  ├─ NATS: JetStream Publish ──────→ NATS ──→ Consumer ──→ Valkey     │
  └─ Valkey Streams: XADD ─────────→ Valkey ──→ Consumer ──→ Valkey   │
                                                                            │
Loadgen: Prometheus + Grafana on same node                                  │
```

## GCP Provisioning

Add a queue broker to existing Cluster A:
```bash
gcloud compute instances create poc-broker \
  --zone=us-central1-a \
  --machine-type=c3-standard-4 \
  --image-family=ubuntu-2404-lts-amd64 \
  --image-project=ubuntu-os-cloud \
  --network-tier=PREMIUM \
  --provisioning-model=SPOT \
  --instance-termination-action=STOP \
  --labels=poc=stg-seats,cluster=a,pocnum=4
```

### Get Internal IPs
```bash
VALKEY_IP=$(gcloud compute instances describe poc-valkey --zone=us-central1-a \
  --format='get(networkInterfaces[0].networkIP)')
BROKER_IP=$(gcloud compute instances describe poc-broker --zone=us-central1-a \
  --format='get(networkInterfaces[0].networkIP)')
```

## Starting Queue Brokers

### Redpanda
```bash
# On broker node
docker compose -f docker-compose.redpanda.yml up -d
# API: localhost:9092
# Admin: localhost:9644
```

### NATS
```bash
# On broker node
docker compose -f docker-compose.nats.yml up -d
# Client: localhost:4222
# Monitoring: localhost:8222
```

### Valkey Streams
No new VM needed — uses the existing Valkey node.
```bash
# No setup — Valkey Streams is built into valkey/valkey:8
```

## Running the Tests

### 1. Seed data (on loadgen node)
```bash
export VALKEY_ADDR=<valkey-internal-ip>
go run ./cmd/seed --valkey-addr=$VALKEY_ADDR
```

### 2. Start consumer (on loadgen node, separate tab)
```bash
export VALKEY_ADDR=<valkey-internal-ip>

# Valkey Streams consumer
go run ./cmd/consumer --queue=valkey-streams \
  --valkey-addr=$VALKEY_ADDR --batch-size=50 --batch-timeout=100ms

# NATS consumer
go run ./cmd/consumer --queue=nats \
  --valkey-addr=$VALKEY_ADDR --nats-url=nats://<broker-ip>:4222 \
  --batch-size=50 --batch-timeout=100ms

# Redpanda consumer
go run ./cmd/consumer --queue=redpanda \
  --valkey-addr=$VALKEY_ADDR --redpanda-brokers=<broker-ip>:9092 \
  --batch-size=50 --batch-timeout=100ms
```

### 3. Run producers at varying rates
```bash
export VALKEY_ADDR=<valkey-internal-ip>
export BROKER_IP=<broker-ip>

# Direct baseline
go run ./cmd/producer --queue=direct --rate=5000 --duration=120s \
  --valkey-addr=$VALKEY_ADDR

# Valkey Streams
go run ./cmd/producer --queue=valkey-streams --rate=5000 --duration=120s \
  --valkey-addr=$VALKEY_ADDR

# NATS
go run ./cmd/producer --queue=nats --rate=5000 --duration=120s \
  --nats-url=nats://$BROKER_IP:4222

# Redpanda
go run ./cmd/producer --queue=redpanda --rate=5000 --duration=120s \
  --redpanda-brokers=$BROKER_IP:9092
```

## Test Phases

| Phase | Focus | What to measure |
|-------|-------|----------------|
| A | Throughput | OPS/sec at 1K/5K/10K/25K/50K producer rate |
| B | E2E latency | p50/p95/p99 from producer send to Valkey execution |
| C | Burst absorption | 100× spike — queue backlog + recovery time |
| D | Batching | Batch size 1/10/50/100/500 — latency vs throughput |
| E | Multi-consumer | 1/2/4 consumers — throughput scaling |

## Interpretation Guide

| Outcome | Condition | Action |
|---------|-----------|--------|
| **Queue unnecessary** | Direct path handles target OPS without Valkey CPU saturation | Skip queue — keep REST-to-Valkey |
| **Queue stabilizes** | Queued path keeps Valkey CPU <70% while direct hits 100% | Adopt queue |
| **Valkey Streams wins** | Comparable latency, zero new infra | Use Valkey Streams |
| **NATS wins** | Lowest e2e latency + lightest footprint | Adopt NATS JetStream |
| **Redpanda wins** | Highest throughput ceiling, best burst absorption | Adopt Redpanda |

## Teardown
```bash
gcloud compute instances delete poc-valkey poc-loadgen poc-broker \
  --zone=us-central1-a --quiet
```
