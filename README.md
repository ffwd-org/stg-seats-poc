# stg-seats-poc — Architecture Proof-of-Concept Monorepo

> **What:** 6 POCs to drive the stg-seats architecture decisions (Seats.io replacement)
> **Repo:** https://github.com/ffwd-org/stg-seats-poc
> **ADR tracked:** ADR-001, ADR-002, ADR-003, ADR-004 (see Architecture Decisions below)

---

## Table of Contents

1. [Background](#background)
2. [ADRs — What We're Deciding](#adrs--what-were-deciding)
3. [Quick Start](#quick-start)
4. [POC Overview](#poc-overview)
5. [Infrastructure](#infrastructure)
6. [Running POCs on GCP](#running-pocs-on-gcp)
7. [Repo Structure](#repo-structure)

---

## Background

stg-seats is a high-concurrency ticketing platform replacing Seats.io. At scale (Taylor Swift-class events), it needs to handle:

- **250,000+ WebSocket connections** per event (real-time seat map updates)
- **100,000+ seats** per event map
- **10,000–50,000 seat holds/second** during on-sale spikes
- **Flash-sale bursts** — 100× normal traffic in seconds
- **Adjacent seat selection** — finding contiguous available runs under fragmentation

This repo runs load tests to answer the open architecture questions before we build the production system.

---

## ADRs — What We're Deciding

| ADR | Question | POCs | Decision Target |
|-----|----------|------|-----------------|
| **ADR-001** | Keep Go WebSockets OR offload to Centrifugo? | POC 2 vs POC 5 | ~Day 3 |
| **ADR-002** | Direct REST-to-Valkey OR Async Intent Queue? | POC 1 vs POC 4 | ~Day 2 |
| **ADR-003** | Go/Valkey Lua OR Pre-computed lists OR Elixir microservice? | POC 3 vs POC 6 | ~Day 4 |
| **ADR-004** | Max safe concurrency per node & waiting room thresholds | POC 1 + POC 5 | ~Day 3 |

---

## Quick Start

```bash
# Clone
git clone https://github.com/ffwd-org/stg-seats-poc
cd stg-seats-poc

# Pick a POC and follow its README
cd poc-1-valkey-contention && cat README.md
```

Each POC directory is self-contained:
- `cmd/` — implementations
- `lua/` — Valkey Lua scripts (where applicable)
- `grafana/dashboard.json` — import into Grafana
- `Makefile` — `make provision`, `make seed`, `make test`, `make teardown`
- `README.md` — full GCP runbook

---

## POC Overview

### POC 1 — Valkey Contention: HSET vs BITFIELD
**Question:** What seat-state encoding scales better on Valkey?

| Encoding | How it works | Memory for 100K seats |
|----------|-------------|----------------------|
| **HSET** | One hash field per seat | ~8–10 MB |
| **BITFIELD** | 2 bits per seat (compact) | ~25 KB |

**Test:** Ramp workers 100 → 100K, measure ops/sec + p99 latency at each stage.

**Result goal:** If HSET sustains ≥150K ops/sec at p99 <10ms → keep HSET. If not → BITFIELD or queue.

**Files:** `poc-1-valkey-contention/`
**GCP cluster:** A (Valkey + loadgen, 2× c3-standard-8 Spot)

---

### POC 2 — Go WebSocket Fan-out Panic
**Question:** Can Go hold 250K persistent WebSocket connections and broadcast reliably?

**Key fix:** Per-connection write mutex + 5s write deadline on the Hub.
```go
func (c *Conn) WriteMessage(msgType int, data []byte) error {
    c.mu.Lock()
    defer c.mu.Unlock()
    c.ws.SetWriteDeadline(time.Now().Add(5 * time.Second))
    return c.ws.WriteMessage(msgType, data)
}
```

**Test phases:**
- Phase A: Idle ramp 10K → 250K connections (measure RAM/GC)
- Phase B: Single broadcast at 250K (measure fan-out time)
- Phase C: Sustained broadcasts 1/sec → 1,000/sec (find the wall)

**Result goal:** If p99 fan-out <100ms at 100 broadcasts/sec → Go is viable. If not → Centrifugo (POC 5).

**Files:** `poc-2-websocket-fanout/`
**GCP cluster:** B (m3-standard-8 WS server + c3-standard-8 loadgen)

---

### POC 3 — Go/Lua Dynamic Best Available Limits
**Question:** Is dynamic adjacent seat search viable at scale, or do we need pre-computed lists?

**Test:** 100K-seat venue, find 2 adjacent available seats under varying fragmentation (0%, 25%, 50%, 80%).

**Algorithm:** Valkey Lua script that:
1. Scans rows filtered by section
2. Finds contiguous runs of available seats
3. Scores by proximity to focal point (center of venue)
4. Returns best contiguous block

**Result goal:** If p99 <50ms at 1K workers / 50% fragmentation → Go/Lua is sufficient. If p99 degrades >200ms → pre-computed lists or Elixir.

**Files:** `poc-3-best-available/`
**GCP cluster:** A (same as POC 1 — no extra cost)

---

### POC 4 — Intent Queue: Redpanda vs NATS vs Valkey Streams
**Question:** Do we need an async queue between the HTTP API and Valkey?

**Compare 4 approaches:**
1. **Direct REST→Valkey** (baseline from POC 1)
2. **Redpanda** — Kafka-compatible, highest throughput
3. **NATS JetStream** — lightest, easiest to operate
4. **Valkey Streams** — zero new infra, uses existing Valkey node

**Test phases:**
- Phase A: Throughput — 1K → 50K requests/sec, measure Valkey CPU
- Phase B: E2E latency — p50/p95/p99 from HTTP response to intent execution
- Phase C: Burst absorption — 100× spike, measure queue backlog + recovery time
- Phase D: Batching — batch size 1 → 500, latency vs throughput tradeoff

**Result goal:** If direct path hits Valkey CPU ceiling at the target OPS → queue wins. If Valkey Streams matches Redpanda latency → use Streams (zero new infra).

**Files:** `poc-4-intent-queue/`
**GCP cluster:** A with queue broker (3× VMs, ~$5/day Spot)

---

### POC 5 — Edge Offload: Centrifugo
**Question:** Does offloading WebSocket management to Centrifugo solve the Go bottleneck?

**Setup:** Go backend becomes a stateless HTTP publisher. Centrifugo handles all 250K connections + fan-out.

**Centrifugo memory claim:** ~2–3KB per connection (vs Go's ~30–50KB). A single 64GB node could hold 250K connections at 750MB.

**Test:** Same phases as POC 2 (idle ramp, single broadcast, broadcast storm) but targeting Centrifugo instead of Go Hub.

**Result goal:** Compare fan-out latency and memory directly against POC 2 results.

**Files:** `poc-5-edge-offload/`
**GCP cluster:** B (same type as POC 2)

---

### POC 6 — Actor Model Engine: Elixir/BEAM
**Question:** Can the BEAM's actor model handle seat state more efficiently than Go/Valkey Lua?

**Architecture:** One GenServer per section (20 sections for 100K seats, 5,000 seats each).
- GenServer state: map of seat_id → {status, holder_token, expiry}
- Timer-based expiry (no TTL keys needed in Valkey)
- `DynamicSupervisor` for on-demand section startup
- Aggregated broadcast via Phoenix Channels or WebSock

**Advantage of BEAM:** Preemptive scheduling, memory isolation per actor, built-in fault tolerance, on-beam OTP patterns.

**Test:** Same load pattern as POC 3 (best-available search), plus 250K WS connections.

**Result goal:** If Elixir maintains p99 <20ms for best-available at 50% fragmentation → serious contender for production.

**Files:** `poc-6-actor-model/`
**GCP cluster:** C (Elixir node + loadgen, 2× c3-standard-8 Spot)

---

## Infrastructure

### GCP Cluster Reference

| Cluster | POCs | VMs | Spot Cost/day |
|---------|------|-----|---------------|
| **A** | 1, 3, 4 | Valkey (c3-standard-8) + loadgen (c3-standard-8) + optional queue broker (c3-standard-4) | ~$4–5 |
| **B** | 2, 5 | WS server (m3-standard-8) + loadgen (c3-standard-8) | ~$6 |
| **C** | 6 | Elixir (c3-standard-8) + loadgen (c3-standard-4) | ~$3 |

**All VMs:** Ubuntu 24.04 LTS, SPOT provisioning, same VPC, same zone (us-central1-a).

### Provisioning
```bash
# Cluster A
cd infra/gcp
./provision-cluster-a.sh

# Cluster B
./provision-cluster-b.sh

# Cluster C
./provision-cluster-c.sh

# Tear down all
./teardown-gcp.sh
```

### OS Tuning (required on all nodes)
```bash
curl -sL https://raw.githubusercontent.com/ffwd-org/stg-seats-poc/main/infra/tune-os.sh | bash
```
This raises nofile to 1,048,576, tunes TCP stack, and disables swap.

### Shared Monitoring
Prometheus + Grafana runs on the loadgen node via `infra/docker-compose.metrics.yml`. Import each POC's `grafana/dashboard.json`.

---

## Repo Structure

```
stg-seats-poc/
├── infra/
│   ├── gcp/                    # GCP provisioning scripts
│   │   ├── provision-cluster-a.sh
│   │   ├── provision-cluster-b.sh
│   │   ├── provision-cluster-c.sh
│   │   └── teardown-gcp.sh
│   ├── digitalocean/           # DO provisioning (same patterns)
│   ├── tune-os.sh              # OS tuning for all VMs
│   └── docker-compose.metrics.yml  # Prometheus + Grafana
├── pkg/
│   └── metrics/
│       └── reporter.go         # Shared Prometheus metrics (all POCs import this)
├── poc-1-valkey-contention/   # HSET vs BITFIELD
│   ├── cmd/seed/               # Valkey data seeder
│   ├── cmd/loadgen/            # Ramp load generator
│   ├── lua/                    # hold_hset.lua, hold_bitfield.lua
│   ├── grafana/dashboard.json
│   ├── Makefile
│   └── README.md
├── poc-2-websocket-fanout/   # Go WebSocket Hub
│   ├── cmd/wsserver/           # Bug-fixed WebSocket server
│   ├── cmd/conngen/            # Connection generator (250K clients)
│   ├── cmd/broadcaster/        # Broadcast rate controller
│   ├── internal/hub/           # Hub implementation
│   ├── internal/conn/          # Per-conn write mutex
│   ├── grafana/dashboard.json
│   ├── Makefile
│   └── README.md
├── poc-3-best-available/      # Adjacency search
│   ├── cmd/seed/               # Realistic venue layout seeder
│   ├── cmd/loadgen/            # Lua script load generator
│   ├── lua/best_available.lua
│   ├── grafana/dashboard.json
│   ├── Makefile
│   └── README.md
├── poc-4-intent-queue/        # Queue comparison
│   ├── cmd/direct/             # Direct-to-Valkey baseline
│   ├── cmd/producer/           # Multi-queue producer
│   ├── cmd/consumer/           # Multi-queue batched consumer
│   ├── internal/queue/          # Redpanda, NATS, Valkey Streams
│   ├── internal/intent/         # Binary codec (44 bytes/HoldIntent)
│   ├── lua/                    # hold_seat.lua
│   ├── grafana/dashboard.json
│   ├── Makefile
│   └── README.md
├── poc-5-edge-offload/        # Centrifugo
│   ├── cmd/centrifugo/          # Centrifugo config + deployment
│   ├── cmd/gowspublisher/       # Stateless Go HTTP publisher
│   ├── cmd/conngen/             # Centrifugo connection generator
│   ├── cmd/broadcaster/         # Centrifugo API broadcaster
│   ├── grafana/dashboard.json
│   ├── Makefile
│   └── README.md
└── poc-6-actor-model/          # Elixir/BEAM
    ├── lib/stg_seats/           # Elixir application
    │   ├── application.ex        # Supervision tree
    │   ├── seat_actor.ex        # GenServer per section
    │   └── hub.ex               # Registry + broadcast
    ├── mix.exs
    ├── cmd/loadgen/             # Go load generator
    ├── grafana/dashboard.json
    ├── Makefile
    └── README.md
```

---

## Execution Plan

| Day | Cluster | POCs | Est. Cost |
|-----|---------|------|-----------|
| 1 | A | POC 1 → POC 3 | ~$4 |
| 2 | A | POC 4 | ~$5 |
| 3 | B | POC 2 → POC 5 | ~$6 |
| 4 | C | POC 6 | ~$3 |
| **Total** | | | **~$18** |

Running sequentially on the same day reuses Cluster A/B VMs — saves ~35% vs isolated runs.

---

## Key Trade-offs Summary

| Decision | Lean | Reason |
|----------|------|--------|
| **Seat encoding** | HSET (for now) | Simpler, good enough unless POC 1 proves otherwise |
| **WebSockets** | Go first, Centrifugo if POC 2 fails | Don't add Centrifugo unless Go hits a wall |
| **Best available** | Dynamic Lua (for now) | Pre-compute only if fragmentation destroys p99 |
| **Intent queue** | Defer unless POC 1 shows Valkey saturation | Direct path is simplest |
| **Actor model** | Watch POC 6 results | BEAM is compelling for seat state + WS management |

---

## Contributing

Each POC is a self-contained load test. To add a new POC:
1. Create `poc-N-name/` directory
2. Implement in `cmd/` with `lua/` scripts if applicable
3. Add `grafana/dashboard.json`
4. Write `README.md` with exact GCP runbook
5. Add `Makefile` with provision/test/teardown targets
6. Commit as `feat(poc-N): add POC-N name`
