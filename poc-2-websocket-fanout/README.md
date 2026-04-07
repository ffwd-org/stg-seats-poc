# POC 2 — Go WebSocket Fan-out Panic

**ADR:** ADR-001 (WebSockets and Real-Time Fan-out), ADR-004 (Capacity Planning)
**Test:** 250K persistent WebSocket connections + broadcast fan-out latency
**Daily infra cost:** GCP Spot ~$5.75 (m3-standard-8 WS + c3-standard-8 loadgen)

## Table of Contents

1. [Architecture](#architecture)
2. [GCP Provisioning](#gcp-provisioning)
3. [Running the Tests](#running-the-tests)
4. [Test Phases](#test-phases)
5. [Metrics & Dashboards](#metrics--dashboards)
6. [Interpretation Guide](#interpretation-guide)
7. [Teardown](#teardown)

---

## Architecture

```
poc-loadgen (c3-standard-8, Spot)       poc-wsserver (m3-standard-8, Spot)
┌──────────────────────────────────┐    ┌──────────────────────────────────┐
│  Go conngen                       │    │  Go wsserver (Hub)               │
│  - Opens N WS connections        │ ←→ │  - Hub: rooms map[event][]conns  │
│  - Holds idle, counts messages   │    │  - Per-conn write mutex + deadline│
│  Prometheus metrics :2113         │    │  Prometheus metrics :2112        │
└──────────────────────────────────┘    └──────────────────────────────────┘
```

### Key Fix: Per-Connection Write Mutex
```go
type Conn struct {
    ws *websocket.Conn
    mu sync.Mutex  // per-connection serialization
}

func (c *Conn) WriteMessage(msgType int, data []byte) error {
    c.mu.Lock()
    defer c.mu.Unlock()
    c.ws.SetWriteDeadline(time.Now().Add(5 * time.Second))
    return c.ws.WriteMessage(msgType, data)
}
```

### Broadcast Path
```
HTTP POST /broadcast/:eventID
  → Hub.Broadcast(eventID, msg)
    → RLock → snapshot conns
      → goroutine per conn
        → conn.WriteMessage()  (each has own mutex)
    → WaitGroup
```

---

## GCP Provisioning

### Prerequisites
```bash
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
gcloud config set zone us-central1-a
gcloud services enable compute.googleapis.com
```

### Provision Cluster B
```bash
# WebSocket server — memory-optimized for 250K connections
gcloud compute instances create poc-wsserver \
  --zone=us-central1-a \
  --machine-type=m3-standard-8 \
  --image-family=ubuntu-2404-lts-amd64 \
  --image-project=ubuntu-os-cloud \
  --network-tier=PREMIUM \
  --provisioning-model=SPOT \
  --instance-termination-action=STOP \
  --labels=poc=stg-seats,cluster=b,pocnum=2

# Load generator
gcloud compute instances create poc-loadgen \
  --zone=us-central1-a \
  --machine-type=c3-standard-8 \
  --image-family=ubuntu-2404-lts-amd64 \
  --image-project=ubuntu-os-cloud \
  --network-tier=PREMIUM \
  --provisioning-model=SPOT \
  --instance-termination-action=STOP \
  --labels=poc=stg-seats,cluster=b,pocnum=2
```

### Get Internal IPs
```bash
WS_IP=$(gcloud compute instances describe poc-wsserver \
  --zone=us-central1-a \
  --format='get(networkInterfaces[0].networkIP)')

LOADGEN_IP=$(gcloud compute instances describe poc-loadgen \
  --zone=us-central1-a \
  --format='get(networkInterfaces[0].networkIP)')

echo "WS_IP=$WS_IP"
echo "LOADGEN_IP=$LOADGEN_IP"
```

### OS Tuning (both nodes)
```bash
curl -sL https://raw.githubusercontent.com/ffwd-org/stg-seats-poc/main/infra/tune-os.sh | bash
```

> **NOTE:** 250K connections from one IP may exhaust ephemeral ports (64K max). Use multiple source IPs:
> ```bash
> # Add 4 secondary IPs to loadgen droplet in GCP Console
> # Then run conngen with: --source-ips=10.10.0.5,10.10.0.6,10.10.0.7,10.10.0.8
> ```

---

## Running the Tests

### On wsserver node:
```bash
# Install Go
curl -sL https://go.dev/dl/go1.24.linux-amd64.tar.gz | sudo tar -C /usr/local -xzf -
export PATH=$PATH:/usr/local/go/bin

# Start WebSocket server
go run ./cmd/wsserver --port=8080 --metrics-port=2112
```

### On loadgen node:
```bash
export WS_IP=<wsserver-internal-ip>

# Phase A: Idle connection ramp
go run ./cmd/conngen \
  --target=ws://$WS_IP:8080/ws/event/1 \
  --connections=250000 \
  --ramp-rate=5000 \
  --metrics-port=2113

# Phase B: Single broadcast
go run ./cmd/broadcaster \
  --target=http://$WS_IP:8080/broadcast/1 \
  --rate=1 --duration=30s

# Phase C: Broadcast storm
go run ./cmd/broadcaster \
  --target=http://$WS_IP:8080/broadcast/1 \
  --rate=100 --duration=120s
```

---

## Test Phases

### Phase A — Idle Connection Ramp
| Stage | Connections | Duration | Measure |
|-------|-------------|----------|---------|
| 1 | 10,000 | 60s idle | Baseline RAM, GC |
| 2 | 50,000 | 60s idle | Memory growth rate |
| 3 | 100,000 | 60s idle | GC pressure signals |
| 4 | 150,000 | 60s idle | Memory per conn stabilized? |
| 5 | 200,000 | 60s idle | Approaching target |
| 6 | 250,000 | 120s idle | Hold at target |

Record per stage: RSS memory, memory/connection, GC pause frequency, goroutine count.

### Phase B — Single Broadcast at 250K
Fire 1 broadcast to all 250K clients. Measure time from HTTP POST to last client receipt. Repeat 10×, take median.

### Phase C — Sustained Broadcast Storm
| Stage | Broadcasts/sec | Duration |
|-------|---------------|----------|
| Low | 1 | 60s |
| Medium | 10 | 60s |
| High | 100 | 120s |
| Extreme | 500 | 120s |
| Breaking | 1,000 | 120s |

Record: fan-out latency p50/p95/p99, dropped connections, GC pauses.

---

## Metrics & Dashboards

Import `grafana/dashboard.json` into Grafana.

| Panel | Metric | Alert threshold |
|-------|--------|----------------|
| Active WS Connections | `poc2_active_connections` | — |
| Goroutine Count | `poc2_goroutine_count` | >100K during broadcast |
| Broadcast Latency p99 | `histogram_quantile(0.99, ...)` | >100ms |
| RSS Memory | `go_memstats_rss_bytes` | Growing without bound |
| GC Pause | `rate(go_gc_pause_seconds_sum)` | >50ms per GC |

---

## Interpretation Guide

| Outcome | Condition | Action |
|---------|-----------|--------|
| **Go WS is viable** | 250K conns + 100 broadcasts/sec at p99 <100ms | Keep Go WS |
| **Go WS works with caveats** | Holds 250K, broadcasts degrade >50/sec or GC >100ms | POC 5 (Centrifugo) becomes critical |
| **Go WS is the bottleneck** | Cannot hold 250K, or fan-out >500ms at 10/sec | Centrifugo mandatory |
| **GC is specific bottleneck** | GOGC=off eliminates GC pauses | Document runtime tuning |

---

## Teardown

```bash
gcloud compute instances delete poc-wsserver poc-loadgen \
  --zone=us-central1-a --quiet
```
