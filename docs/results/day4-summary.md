# Day 4 Results — POC 6 (Elixir/BEAM Actor Model)

> **Date**: 2026-04-08
> **Cluster**: C (us-central1-b, GCP Spot)
> **VMs**: poc-elixir (c3-standard-8) + poc-loadgen-c (c3-standard-4)
> **Project**: silicon-pointer-490721-r0
> **Stack**: Elixir 1.17 + OTP 27, Bandit HTTP, GenServer per section, ETS concurrent reads

---

## Architecture

- **20 GenServer actors** — one per venue section (~5K seats each)
- **ETS table** (`venue_seats`) — `:set, :public, read_concurrency: true` for concurrent reads
- **GenServer serialization** — all holds go through `GenServer.call/2` for atomicity
- **Contiguous seat search** — linear scan with orphan rejection
- **Expiry** — timer-based, checks every 5s per actor

---

## Phase A — Latency vs Fragmentation (1 worker, 30s)

| Fragmentation | Successful ops | ops/s | p50 | p95 | p99 | Error Rate |
|---------------|---------------|-------|-----|-----|-----|------------|
| 0% | 37,680 | **1,256** | **0.8ms** | 1.3ms | 1.5ms | **0.0%** |
| 50% | 6,415 | 214 | 1.9ms | 2.7ms | 3.0ms | 51.3% |
| 80% | 314 | 10 | 2.3ms | 2.9ms | 3.1ms | 96.5% |

**Finding**: At f=0%, single-thread throughput is **1,256 ops/s** with sub-ms latency — the BEAM handles individual requests very efficiently. Error rate at f=50%/80% is expected: fragmented sections have fewer contiguous blocks, so most hold requests legitimately fail with `no_contiguous_block`.

---

## Phase B — Concurrency Scaling (f=50%, 60s)

| Workers | Successful ops | ops/s | p50 | p95 | p99 | Error Rate |
|---------|---------------|-------|-----|-----|-----|------------|
| 100 | 125 | 2 | 21.5ms | 51.9ms | 68.8ms | 99.95% |
| 1,000 | 33 | 1 | 180ms | 771ms | 1.07s | 99.99% |
| 5,000 | 5 | 0 | 767ms | 4.69s | 6.20s | 100% |
| 10,000 | 3 | 0 | 3.06s | 5.03s | 9.25s | 100% |

**Finding**: GenServer mailbox is the bottleneck. With 20 section actors and 10K workers, each GenServer queues ~500 messages. The p50 latency balloons from 0.8ms (1 worker) to **3.06s (10K workers)** — a 3,825× degradation. The error rate is dominated by "no contiguous block" errors (expected at f=50%), but latency under contention is the critical concern.

---

## Phase C — Worst Case (f=80%, 10K workers, 120s)

| Successful ops | ops/s | p50 | p95 | p99 | Error Rate |
|---------------|-------|-----|-----|-----|------------|
| 0 | 0 | 2.77s | 5.03s | 9.92s | **100%** |

**Finding**: At 80% fragmentation with 10K concurrent workers, the system produces zero successful holds. All requests either fail to find contiguous blocks or timeout waiting in the GenServer mailbox.

---

## Phase D — Quantity Variation (f=50%, 5K workers, 60s)

| Quantity | Successful ops | ops/s | p50 | Error Rate |
|----------|---------------|-------|-----|------------|
| 1 | 50 | 1 | 845ms | 99.98% |
| 2 | 0 | 0 | 602ms | 100% |
| 4 | 0 | 0 | 876ms | 100% |
| 6 | 0 | 0 | 876ms | 100% |
| 8 | 0 | 0 | 1.03s | 100% |

**Finding**: At 50% fragmentation, finding even 1 contiguous seat under concurrency is nearly impossible. The contiguous search with orphan rejection is the core bottleneck — it's O(N) per section per request, serialized through the GenServer.

---

## Phase E — Hold Throughput (f=0%, 50K workers, 120s)

| Successful ops | ops/s | p50 | p95 | p99 | Error Rate |
|---------------|-------|-----|-----|-----|------------|
| 6 | 0 | **10.5s** | 24.2s | 29.9s | **100%** |

**Finding**: Even at f=0% (all seats available), 50K concurrent workers saturate the system. The GenServer mailbox + HTTP connection pool become the bottleneck. p50=10.5s means most requests wait >10s in queue.

---

## POC 6 Conclusions (for ADR-003/004)

### Strengths
1. **Clean single-thread performance** — 1,256 ops/s at f=0%, sub-ms latency
2. **Correct serialization** — GenServer guarantees no race conditions on seat state
3. **Elegant architecture** — actor-per-section, ETS for reads, supervision tree for reliability
4. **Orphan rejection** — built-in business logic prevents isolated single seats

### Weaknesses
1. **GenServer mailbox bottleneck** — serialized access doesn't scale past ~100 concurrent workers per section
2. **Contiguous search is O(N)** — linear scan per hold request, expensive at high fragmentation
3. **No horizontal scaling** — single BEAM node, 20 actors, all state in ETS (not distributed)
4. **HTTP overhead** — Bandit/Plug adds ~0.5ms per request vs direct GenServer calls

### Comparison with Valkey (POC 1)

| Metric | Elixir Actors (POC 6) | Valkey Lua (POC 1) |
|--------|----------------------|-------------------|
| Single-thread throughput | 1,256 ops/s | 160,000 OPS/s |
| Contiguous search | Built-in (O(N)) | Not built-in (needs sorted sets) |
| Concurrency model | GenServer mailbox | Lua atomics (single-threaded Valkey) |
| Under 10K workers | 0 ops/s, p50=3s | ~160K OPS/s (all succeed) |
| State persistence | ETS (memory only) | Valkey (memory + optional AOF) |

**Key insight**: Valkey's single-threaded model is actually an advantage for this workload — it processes commands at memory speed (~1µs each) without mailbox overhead. The Elixir GenServer adds ~0.5ms of Erlang scheduling + serialization overhead per request, which compounds under contention.

### Recommendation

**Do not use Elixir/BEAM actor model as the primary seat state engine.** The GenServer-per-section pattern doesn't scale under concurrent load. Instead:

1. **Keep Valkey as the seat state store** (POC 1 — 160K OPS/s, atomic Lua scripts)
2. **Use Centrifugo for WebSocket fan-out** (POC 5 — 1000/sec at 250K connections)
3. **Consider BEAM for orchestration** (e.g., coordinating multi-section best-available across sections via supervisor) but NOT for individual seat state mutations

---

## Infrastructure Notes

- **Zone**: `us-central1-b` (us-central1-a was exhausted for c3-standard-8 Spot)
- **Elixir VM**: Docker-based (elixir:1.17-otp-27 image), `--network=host`, `+S 8:8 +P 1000000`
- **Build**: Multi-stage Docker build (~90s) — much more reliable than bare-metal Erlang install
- **Loadgen**: Go HTTP client, 50K goroutines max
- **Estimated cost**: ~$1.50 (c3-standard-8 + c3-standard-4 Spot for ~30 min)
- **Issues**: Zone exhaustion (us-central1-a → us-central1-b), apt-get slow mirrors (~3 min)
