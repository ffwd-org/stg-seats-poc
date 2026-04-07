# POC 6 — Actor Model Engine: Elixir/BEAM

**ADR:** ADR-003 (Go/Valkey Lua vs Pre-computed lists vs Elixir)
**Test:** GenServer-based seat state management vs Go/Valkey Lua
**Daily infra cost:** GCP Spot ~$3.00 (c3-standard-8 Elixir + c3-standard-4 loadgen)

## Architecture

```
Elixir Node (c3-standard-8)
┌─────────────────────────────────────────────────────────┐
│  StgSeats.Application                                   │
│    ├── StgSeats.Hub (GenServer — aggregated API)        │
│    │     ├── HubRegistry (Registry — event_id → pids)   │
│    │     └── SectionSupervisor (DynamicSupervisor)      │
│    └── StgSeats.SeatActor × 20 (one per section)       │
│          5,000 seats each                               │
│          Timer-based expiry                              │
│          Binary codec (44 bytes/hold)                   │
└─────────────────────────────────────────────────────────┘
```

### Why 20 GenServers?
- **One per section** (100,000 seats / 20 sections = 5,000 seats/actor)
- No bottleneck: each GenServer runs in its own BEAM scheduler (one per CPU core)
- Supervision: if one section crashes, only that section's 5K seats are affected

### Actor State
```elixir
%{
  section_id: 0,
  seats: %{
    0 => :available,
    1 => {:held, "token-abc", 1712500000},  # token + expiry
    ...
  }
}
```

## GCP Provisioning

```bash
# Elixir/BEAM node
gcloud compute instances create poc-elixir \
  --zone=us-central1-a \
  --machine-type=c3-standard-8 \
  --image-family=ubuntu-2404-lts-amd64 \
  --image-project=ubuntu-os-cloud \
  --network-tier=PREMIUM \
  --provisioning-model=SPOT \
  --instance-termination-action=STOP \
  --labels=poc=stg-seats,cluster=c,pocnum=6

# Load generator
gcloud compute instances create poc-loadgen \
  --zone=us-central1-a \
  --machine-type=c3-standard-4 \
  --image-family=ubuntu-2404-lts-amd64 \
  --image-project=ubuntu-os-cloud \
  --network-tier=PREMIUM \
  --provisioning-model=SPOT \
  --instance-termination-action=STOP \
  --labels=poc=stg-seats,cluster=c,pocnum=6
```

## Elixir Setup (on elixir node)

```bash
# Install Erlang + Elixir
curl -fsSL https://packages.erlang-solutions.com/ubuntu/erlang.repo | sudo tee /etc/apt/sources.list.d/erlang.list
sudo apt-get update && sudo apt-get install -y erlang elixir

# Verify
elixir --version
Erlang/OTP 26 [erts-14.2.5] ... Elixir 1.16.3

# Apply OS tuning
curl -sL https://raw.githubusercontent.com/ffwd-org/stg-seats-poc/main/infra/tune-os.sh | bash

# Install dependencies
mix deps.get
mix deps.compile
```

## Running the Tests

### 1. Start Elixir application
```bash
ELIXIR_IP=$(curl -s http://metadata.google.internal/computeMetadata/v1/instance/networkInterfaces/0/ip)
iex --name stg_seats@$ELIXIR_IP -S mix
```

### 2. Run load tests (on loadgen node)
```bash
export ELIXIR_IP=<elixir-internal-ip>

# Basic hold operations
go run ./cmd/loadgen \
  --target=http://$ELIXIR_IP:4000 \
  --workers=1000 \
  --duration=120s

# High concurrency ramp
go run ./cmd/loadgen \
  --target=http://$ELIXIR_IP:4000 \
  --workers=5000 \
  --duration=120s
```

## Test Phases

| Phase | Focus | What to measure |
|-------|-------|----------------|
| A | Basic throughput | GenServer ops/sec at 1K/5K workers |
| B | Timer expiry | Memory after 60s TTL expiry (BEAM GC) |
| C | Actor restart | Recovery time after DynamicSupervisor restart |
| D | Comparison | vs POC 3 (Go/Lua) and POC 1 (Valkey HSET) |

## Interpretation Guide

| Outcome | Condition | Action |
|---------|-----------|--------|
| **Elixir viable** | >50K ops/sec, p99 <10ms, stable memory | Consider Elixir for seat management |
| **BEAM scheduler bottleneck** | ops/sec plateaus below 50K | GenServer-per-seat or OTP Release needed |
| **Go/Lua wins** | Go/Lua achieves higher ops/sec at lower cost | Stick with Go/Valkey (POC 1 + 3) |
| **Hybrid wins** | Elixir for state, Go for WS fan-out | Use Elixir for seat state only |

## Teardown
```bash
gcloud compute instances delete poc-elixir poc-loadgen \
  --zone=us-central1-a --quiet
```
