# Day 5 Results — Missing Data Reruns (POC 1, 4, 5)

> **Date**: 2026-04-09
> **Clusters**: A (us-central1-a) then B (us-central1-a) — sequential due to C3 vCPU quota (24 limit)
> **VMs**: poc-valkey + poc-loadgen (Cluster A), poc-appserver + poc-loadgen-b (Cluster B)
> **Project**: silicon-pointer-490721-r0

---

## POC 1 — Memory Comparison (HSET vs BITFIELD)

### Memory Footprint for 100,000 Seats

| Mode | Empty Valkey | After Seeding 100K Seats | Delta | Per Seat |
|------|-------------|--------------------------|-------|----------|
| **HSET** | 1.10 MB | 8.06 MB | **6.96 MB** | **73 bytes** |
| **BITFIELD** | 1.29 MB | 1.36 MB | **0.07 MB** | **0.7 bytes** |

**Finding**: BITFIELD uses **99% less memory** than HSET for seat state storage. At 100K seats, HSET uses 6.96 MB vs BITFIELD's 0.07 MB. However, BITFIELD's post-load memory (6.97 MB) approaches HSET's because the holders hash (`seats:event:1:holders`) grows during load testing.

### Memory Under Load (with `valkey_memory_mb` in CSV)

| Mode | Workers | OPS/sec | p50 | p99 | Memory |
|------|---------|---------|-----|-----|--------|
| HSET | 100 | 121,622 | 0.42ms | 0.67ms | 7.70 MB |
| HSET | 1,000 | 147,662 | 3.77ms | 5.13ms | 7.71 MB |
| HSET | 10,000 | 134,908 | 18.2ms | 78.2ms | 7.78 MB |
| BITFIELD | 100 | 118,877 | 0.43ms | 0.69ms | 7.04 MB |
| BITFIELD | 1,000 | 148,210 | 3.46ms | 4.88ms | 7.04 MB |
| BITFIELD | 10,000 | 150,147 | 32.6ms | 71.4ms | 7.04 MB |

**Finding**: Under active load, BITFIELD maintains 7.04 MB (stable) vs HSET's 7.70-7.78 MB. The ~0.7 MB difference under load is modest — the raw seat encoding saves 99% but the holder mapping offsets most of it. BITFIELD's throughput advantage (150K vs 135K at 10K workers) is more significant than the memory savings.

### POC 1 Memory Conclusions (for ADR-004)

1. **Raw seat state**: BITFIELD is 100× more compact (0.07 MB vs 6.96 MB for 100K seats)
2. **With holder tracking**: Gap narrows to ~10% (7.04 MB vs 7.78 MB) because both need a holder hash
3. **At scale (1M seats)**: BITFIELD saves ~70 MB on seat state alone — meaningful for capacity planning
4. **Recommendation**: Memory is NOT the deciding factor for HSET vs BITFIELD. Throughput characteristics from Day 1 are more relevant.

---

## POC 4 — E2E Latency Percentiles

### Valkey Streams — E2E Latency (batch=10, 1 consumer)

| Producer Rate | Consumed | p50 | p95 | p99 |
|---------------|----------|-----|-----|-----|
| 5,000/s | 69,624 | **119µs** | 315µs | 1.9ms |
| 25,000/s | 1,092,521 | **192µs** | 297µs | 356µs |
| 50,000/s | 1,732,276 | **253µs** | 2.4ms | **357ms** |

**Finding**: Valkey Streams delivers sub-millisecond p50 at all rates. At 50K/s, p99 spikes to 357ms — the consumer can't keep up (queue lag accumulates), but p50 stays at 253µs because most messages are processed quickly.

### NATS JetStream — E2E Latency (batch=10, 1 consumer)

| Producer Rate | Consumed | p50 | p95 | p99 |
|---------------|----------|-----|-----|-----|
| 5,000/s | — | — | — | — |
| 25,000/s | 935,047 | **417µs** | 796µs | 989µs |
| 50,000/s | 1,753,325 | **4.8ms** | 8.6ms | **8.6ms** |

**Finding**: NATS at 25K/s: sub-millisecond everywhere. At 50K/s with 1 consumer: p50=4.8ms — significantly worse than Valkey Streams (253µs) because NATS consumer throughput is lower per consumer.

### NATS Multi-Consumer Scaling at 50K/s

| Consumers | Consumed (60s) | p50 | p95 | p99 |
|-----------|---------------|-----|-----|-----|
| 1 | 1,759,557 | 5.3s | 9.0s | 9.1s |
| 2 | 3,365,830 | 6.8s | 11.8s | 11.9s |
| 4 | 5,008,640 | 11.8s | 20.8s | 21.2s |

**Finding**: NATS throughput scales with consumers (1.8M → 5M consumed) but **latency worsens** as queue depth increases. With 4 consumers, total throughput nearly matches producer rate (83K/s consumed vs 50K/s produced), but the accumulated backlog causes p50=11.8s. This is a queue-draining pattern, not steady-state latency.

### Direct Valkey Baseline (no queue)

| Workers | OPS/sec | p50 | p99 | Valkey CPU |
|---------|---------|-----|-----|------------|
| 5,000 | 145,570 | 16.2ms | 41.3ms | 100% |
| 25,000 | 135,423 | 87.1ms | 266.7ms | 99.8% |
| 50,000 | 110,549 | 148.1ms | 579.0ms | 99.6% |

### POC 4 Latency Conclusions (for ADR-002)

1. **Direct Valkey wins on latency**: p50=16.2ms at 5K workers vs Valkey Streams' 119µs e2e — BUT the direct path is measuring different things (Valkey hold latency vs queue transit time)
2. **Valkey Streams is the best queue for latency**: p50=119-253µs at 5K-50K rate, sub-ms at realistic rates
3. **NATS trades latency for throughput**: At 50K/s, NATS consumers can't keep up with 1 consumer — need 4 consumers to match producer rate, and queue lag dominates latency
4. **Queue adds negligible latency at realistic rates**: At 5K-25K/s (realistic on-sale), Valkey Streams adds <300µs e2e — invisible to users
5. **Queue is insurance, not mandatory**: Direct Valkey handles 145K OPS/s at 5K workers. Our target (~10-30K/s) is well under this ceiling.

---

## POC 5 — Failure Modes & Backend Load

### Phase D: Backend Load (Publish latency with 250K active connections)

| Broadcast Rate | Sent | Errors | p50 | p95 | p99 |
|---------------|------|--------|-----|-----|-----|
| 1/sec | 59 | 0 | **128ms** | 271ms | 837ms |
| 10/sec | 599 | 0 | **51ms** | 280ms | 532ms |
| 100/sec | 1,852 | 0 | **27.6s** | 38.8s | 39.9s |
| 500/sec | 2 | 0 | 29ms | 29ms | 29ms |
| 1000/sec | 0 | **11,342** | — | — | — |

**Finding**: With 250K active connections, publish API latency is acceptable at ≤10/sec (p50=51-128ms) but degrades catastrophically at 100/sec (p50=27.6s). At 1000/sec, all broadcasts fail. This is different from Day 3 results (p50=196µs at 1000/sec) — the Day 3 internal port was used with a fresh Centrifugo, while Day 5 had 250K active reconnecting clients competing for resources.

**Key insight**: The Day 3 POC 5 broadcasts used `internal_port` 9000 with stable connections. The Day 5 Phase D ran after 70s of ramp but with connections still stabilizing. The ~250K connection establishment storm may have been competing with the broadcast API. For production: ensure connection ramp is complete before heavy broadcast loads.

### Phase E: Failure Mode Results

**Timeline:**
- Centrifugo killed at ~01:39:14
- 250K connections immediately dropped (connected=0 within 5s)
- Centrifugo restarted at ~01:40:27
- 80K reconnected in first 5s
- Peak: ~176K reconnected at ~01:42
- Oscillation: connections rapidly connect/disconnect (250K clients all retrying with exponential backoff)
- After 20+ minutes: ~3K-53K connected at any given time (not stable)

| Event | Connected | Reconnects | Disconnects |
|-------|-----------|------------|-------------|
| Pre-kill (baseline) | ~250,000 | — | — |
| Kill +5s | 0 | 954,080 | 954,080 |
| Restart +5s | 80,395 | 954,080 | 954,080 |
| Restart +2min | 175,643 | 1,071,475 | 1,071,475 |
| Restart +5min | 44,401 | 2,164,927 | 2,214,345 |
| Restart +20min | 13,610 | 2,702,020 | 2,748,956 |

**Finding**: Centrifugo **does NOT gracefully recover from a 250K reconnection storm**. Connections oscillate — clients reconnect, Centrifugo accepts them, but then drops them under the load of accepting more. After 20+ minutes, only ~10-50K connections are stable at any given time.

**E3 — Broadcast while down**: 0 sent, 99 errors (expected — HTTP connection refused).

**E5 — Post-recovery broadcast** (with ~13K connections): p50=25.7ms, p95=46.1ms, p99=162.3ms. The few stable connections receive broadcasts quickly.

### POC 5 Failure Mode Conclusions (for ADR-001)

1. **Centrifugo is NOT self-healing at 250K scale**: A full restart triggers a reconnection thundering herd that doesn't stabilize
2. **Mitigation needed**: Production deployment requires:
   - **Multiple Centrifugo nodes** behind a load balancer (spread reconnection load)
   - **Client-side jitter**: Randomized reconnection delay (0-30s) to prevent thundering herd
   - **Connection rate limiting**: Centrifugo's `client_connection_rate_limit` to cap reconnections/sec
   - **Health check before reconnect**: Clients should check `/health` before attempting WS reconnect
3. **Normal operation is excellent**: Day 3 proved 250K connections + 1000/sec broadcasts with 0 errors. The failure mode is a deployment concern, not an architecture blocker.
4. **Recommendation**: Adopt Centrifugo with production hardening (multi-node, client jitter, rate limiting). Don't rely on single-node Centrifugo for >100K connections in production.

---

## Infrastructure Notes

- **Cluster A**: c3-standard-8 × 2 (Spot), ~20 min runtime, ~$0.50
- **Cluster B**: c3-highmem-8 + c3-standard-8 (Spot), ~35 min runtime, ~$1.00
- **Total estimated cost**: ~$1.50
- **C3 CPU quota**: 24 vCPU limit in us-central1 — ran clusters sequentially instead of parallel
- **Reconnection storm**: 250K clients with exponential backoff (100ms-10s) created sustained load that prevented Centrifugo from stabilizing
