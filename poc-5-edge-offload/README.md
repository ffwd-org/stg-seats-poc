# POC 5 — Edge Offload: Centrifugo

**ADR:** ADR-001 (WebSockets and Real-Time Fan-out)
**Test:** Offload 250K WS connections from Go to Centrifugo, compare fan-out
**Daily infra cost:** GCP Spot ~$5.75 (Cluster B — same VMs as POC 2)

> Reuses Cluster B from POC 2 — just swap the Go WS server for Centrifugo.

## Architecture

```
poc-loadgen (c3-standard-8)                      poc-centrifugo (m3-standard-8)
┌──────────────────────────────────────┐   ┌──────────────────────────────────┐
│  conngen (250K clients)              │   │  Centrifugo v5                    │
│  broadcaster                         │ ←→│  Redis (channel history)           │
│  Prometheus + Grafana                │   │  250K persistent connections      │
└──────────────────────────────────────┘   │  ~2-3KB/conn ≈ 500MB-1GB RAM     │
                                           └──────────────────────────────────┘
Go backend (stateless):
  POST /publish/:event → Centrifugo HTTP API
  No WS connections held
```

## GCP Provisioning

Use Cluster B from POC 2 (swap app server):
```bash
# Centrifugo node — same m3-standard-8 as POC 2's Go WS server
gcloud compute instances create poc-centrifugo \
  --zone=us-central1-a \
  --machine-type=m3-standard-8 \
  --image-family=ubuntu-2404-lts-amd64 \
  --image-project=ubuntu-os-cloud \
  --network-tier=PREMIUM \
  --provisioning-model=SPOT \
  --instance-termination-action=STOP \
  --labels=poc=stg-seats,cluster=b,pocnum=5
```

### OS Tuning (both nodes)
```bash
curl -sL https://raw.githubusercontent.com/ffwd-org/stg-seats-poc/main/infra/tune-os.sh | bash
```

## Starting Centrifugo

SSH to Centrifugo node:
```bash
# Edit config with Redis IP (from docker-compose sidecar or separate Redis VM)
# Then:
docker compose up -d

# Verify
curl http://localhost:8000/health
# {"status":"ok"}
```

## Running the Tests

### 1. Start conngen (on loadgen node)
```bash
export CENTRIFUGO_IP=<centrifugo-internal-ip>

# Connect 250K clients
go run ./cmd/conngen \
  --target=ws://$CENTRIFUGO_IP:8000/connection/uni_subscribe \
  --connections=250000 \
  --ramp-rate=5000
```

### 2. Run broadcast storm (on loadgen node)
```bash
# Low rate baseline
go run ./cmd/broadcaster \
  --target=http://$CENTRIFUGO_IP:8000/api \
  --rate=1 --duration=60s

# High rate (comparable to POC 2 Phase C)
go run ./cmd/broadcaster \
  --target=http://$CENTRIFUGO_IP:8000/api \
  --rate=100 --duration=120s
```

### 3. Go backend (optional — measures handoff latency)
```bash
go run ./cmd/gowspublisher \
  --centrifugo-url=http://$CENTRIFUGO_IP:8000/api \
  --port=8080
```

## Key Metric: Memory per Connection

Centrifugo is purpose-built for massive fan-out. At 250K connections:
- **Centrifugo:** ~2-3KB/connection ≈ **500MB-1GB RAM** total
- **Go WS (POC 2):** ~30-50KB/connection ≈ **8-12GB RAM** at 250K

This is the primary comparison: can Centrifugo handle our load with a fraction of the memory?

## Interpretation Guide

| Outcome | Condition | Action |
|---------|-----------|--------|
| **Centrifugo wins clearly** | Holds 250K at <1GB RAM + lower fan-out latency | Replace Go WS with Centrifugo |
| **Centrifugo wins on memory** | Memory <20% of Go WS at same connections | Adopt Centrifugo for WS management |
| **Centrifugo not needed** | Go WS (POC 2) handles 250K cleanly | Keep Go WS |
| **Hybrid wins** | Go handles business logic, Centrifugo for fan-out | Use Centrifugo for WS only |

## Teardown
```bash
gcloud compute instances delete poc-centrifugo poc-loadgen \
  --zone=us-central1-a --quiet
```
