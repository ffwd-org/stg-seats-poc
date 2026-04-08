# Day 3 Results — POC 2 (Go WebSocket Fan-out) + POC 5 (Centrifugo Edge Offload)

> **Date**: 2026-04-08
> **Cluster**: B (us-central1-a, GCP Spot)
> **VMs**: poc-appserver (c3-highmem-8, 64GB) + poc-loadgen-b (c3-standard-8, 32GB)
> **Project**: silicon-pointer-490721-r0

---

## POC 2: Go WebSocket Fan-out

Custom Go WS hub with per-connection write mutex, goroutine-per-broadcast fan-out.

### Phase A — Connection Ramp (idle)

| Target | Actual Connected | Notes |
|--------|-----------------|-------|
| 10,000 | 10,000 | OK |
| 50,000 | ~40,000 | Timeout at 120s (ramp not complete) |
| 100,000 | ~64,000 | Port exhaustion — single source IP |
| 150,000 | ~64,000 | Same limit |
| 200,000 | ~64,000 | Same limit |
| 250,000 | ~64,000 | Same limit |

**Finding**: Single source IP caps at ~64K connections (ephemeral port range). After adding 4 alias IPs (10.128.10.1-4), Phase B achieved **206K+ connections**.

### Phase B — Broadcast Storm (~200K+ connections, 4 source IPs)

| Rate | Sent | Errors | p50 | p95 | p99 |
|------|------|--------|-----|-----|-----|
| 1/sec | 119 | 0 | **354ms** | 393ms | 1.67s |
| 10/sec | 59 | 326 | 44.7s | 1m48s | 1m49s |
| 100/sec | 0 | 11,283 | — | — | — |
| 500/sec | 0 | 44,678 | — | — | — |
| 1000/sec | 0 | 86,932 | — | — | — |

**Finding**: Go hub hits a hard fan-out wall at ~1 broadcast/sec with 200K connections. The `Hub.Broadcast()` spawns a goroutine per connection per message — at 200K connections and 10/sec, that's 2M goroutines/sec competing for write access, overwhelming the Go scheduler.

### POC 2 Conclusions

1. **Connection scaling is fine** — 200K+ connections with 4 source IPs, stable at idle
2. **Fan-out is the bottleneck** — goroutine-per-connection broadcast doesn't scale past 1/sec at 200K
3. **p50=354ms for single broadcast** — acceptable for infrequent seat updates, but not for high-rate events
4. **Needs architectural change** — batch writes, epoll-based fan-out, or edge offload (→ POC 5)

---

## POC 5: Centrifugo v5 Edge Offload

Centrifugo handles all WebSocket connections. Go backend publishes via HTTP API.

### Phase A — Connection Ramp (idle)

| Target | Status | Notes |
|--------|--------|-------|
| 10,000 | OK | |
| 50,000 | OK | |
| 100,000 | OK | |
| 150,000 | OK | |
| 200,000 | OK | |
| 250,000 | OK | All 6 levels passed |

**Finding**: Centrifugo handles 250K connections without issue. All ramp levels completed within the 120s timeout.

### Phase B — Broadcast Storm (250K connections, API via internal port 9000)

| Rate | Sent | Errors | p50 | p95 | p99 |
|------|------|--------|-----|-----|-----|
| 1/sec | 119 | **0** | **37.8ms** | 160ms | 178ms |
| 10/sec | 1,199 | **0** | **374µs** | 466µs | 519µs |
| 100/sec | 11,999 | **0** | **284µs** | 345µs | 386µs |
| 500/sec | 59,999 | **0** | **199µs** | 247µs | 277µs |
| 1000/sec | 114,808 | **0** | **196µs** | 251µs | 293µs |

**Finding**: Centrifugo broadcasts at 1000/sec to 250K connections with **sub-millisecond API latency** and **zero errors**. Fan-out is handled by Centrifugo's internal epoll-based write scheduling — the Go backend only makes one HTTP POST per broadcast.

### POC 5 Conclusions

1. **Centrifugo handles 250K connections trivially** — no tuning beyond OS-level `ulimit`/`sysctl`
2. **1000 broadcasts/sec at 250K connections, 0 errors** — massive headroom for our use case (~10 seat updates/sec per event)
3. **Sub-millisecond publish latency** — p50=196µs at 1000/sec, the bottleneck is NOT Centrifugo
4. **Must use internal_port for API** — publishing on the same port as 250K WS connections causes TCP contention. Use port 9000 (internal) for server-side publish
5. **JWT auth works** — each client authenticates via HMAC-signed JWT token

---

## Head-to-Head Comparison (for ADR-001)

| Metric | Go WS Hub (POC 2) | Centrifugo (POC 5) | Winner |
|--------|-------------------|-------------------|--------|
| Max connections | 200K+ (with multi-IP) | 250K | Centrifugo |
| 1/sec broadcast p50 | 354ms | 37.8ms | **Centrifugo (9.4×)** |
| 10/sec broadcast | FAILED | 374µs, 0 errors | **Centrifugo** |
| 100/sec broadcast | FAILED | 284µs, 0 errors | **Centrifugo** |
| 1000/sec broadcast | FAILED | 196µs, 0 errors | **Centrifugo** |
| Max broadcast rate | ~1/sec | **1000+/sec** | **Centrifugo (1000×)** |
| Infrastructure | Zero (Go binary) | Centrifugo container | Go hub simpler |
| Operational model | Stateful (holds all conns) | Stateless Go + stateful edge | Centrifugo separates concerns |

**Recommendation for ADR-001**: Use Centrifugo as the WebSocket edge layer. The Go backend publishes seat updates via HTTP to Centrifugo's internal port. This decouples connection management from business logic and provides 1000× better fan-out throughput.

---

## Infrastructure Notes

- **App server**: c3-highmem-8 (8 vCPU, 64GB RAM) — SPOT, preempted once during test
- **Loadgen**: c3-standard-8 (8 vCPU, 32GB RAM) — SPOT, no preemption
- **Multi-IP**: 4 alias IPs (10.128.10.0/28) required on loadgen for >64K outbound connections
- **Centrifugo**: v5, single-node, `--network=host`, memory engine (no Redis needed for single-node)
- **OS tuning**: `ulimit -n 1048576`, `net.core.somaxconn=65535`, `net.ipv4.tcp_tw_reuse=1`
- **Estimated cost**: ~$2.50 (c3-highmem-8 + c3-standard-8 Spot for ~2.5 hours)

### Issues Encountered

1. **m3-standard-8 unavailable** — used c3-highmem-8 instead (same 8 vCPU, 64GB)
2. **Port exhaustion at 64K** — fixed with alias IP range on loadgen
3. **Centrifugo API contention** — publishing on port 8000 (same as WS) fails under 250K connections. Must use internal_port (9000) with `api_insecure: true`
4. **Spot preemption** — app server preempted mid-test, had to restart and re-run POC 5 broadcast
5. **SSH via IAP unreliable** — timeouts frequent under load, SCP+bash script pattern works better
6. **Startup script race** — original script's metadata signals persisted across VM restart, causing rapid phase-skip on reboot
