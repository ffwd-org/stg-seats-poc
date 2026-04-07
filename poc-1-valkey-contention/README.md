# POC 1 — Valkey Seat Hold Contention: HSET vs BITFIELD

Measures throughput and latency of two Lua-scripted hold approaches under increasing concurrency.

## Prerequisites

```bash
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
```

Ubuntu 24.04 LTS image family: `ubuntu-2404-lts-amd64` (project `ubuntu-os-cloud`)

## 1. Provision VMs

```bash
# Valkey node
gcloud compute instances create poc-valkey \
  --zone=us-central1-a --machine-type=c3-standard-8 \
  --image-family=ubuntu-2404-lts-amd64 --image-project=ubuntu-os-cloud \
  --network-tier=PREMIUM --provisioning-model=SPOT \
  --labels=poc=stg-seats,cluster=a

# Load generator node
gcloud compute instances create poc-loadgen \
  --zone=us-central1-a --machine-type=c3-standard-8 \
  --image-family=ubuntu-2404-lts-amd64 --image-project=ubuntu-os-cloud \
  --network-tier=PREMIUM --provisioning-model=SPOT \
  --labels=poc=stg-seats,cluster=a
```

## 2. Discover Internal IPs

```bash
gcloud compute instances list \
  --filter="name~poc-" \
  --format="table(name, networkInterfaces[0].networkIP, status)"
```

## 3. OS Tuning (both nodes)

```bash
# SSH into each node and run:
curl -fsSL https://raw.githubusercontent.com/ffwd-org/stg-seats-poc/main/infra/tune-os.sh | bash
```

## 4. Start Valkey (on poc-valkey node)

```bash
docker run -d --name valkey \
  -p 6379:6379 \
  -v valkey-data:/data \
  valkey/valkey:8 \
  --maxmemory 12gb \
  --maxmemory-policy allkeys-lru \
  --save "" \
  --loglevel notice
```

### Valkey exporter sidecar

```bash
docker run -d --name valkey-exporter \
  -p 9121:9121 \
  -e REDIS_ADDR=redis://localhost:6379 \
  oliver006/valkey_exporter:v1.16.0
```

## 5. Build and deploy loadgen (on poc-loadgen node)

```bash
git clone https://github.com/ffwd-org/stg-seats-poc.git
cd stg-seats-poc/poc-1-valkey-contention
go build ./cmd/seed ./cmd/loadgen
```

## 6. Seed data

Replace `VALKEY_IP` with the internal IP of poc-valkey.

```bash
VALKEY_ADDR=VALKEY_IP:6379

# Seed HSET approach
go run ./cmd/seed --mode=hset --seats=100000 --valkey-addr=$VALKEY_ADDR

# Seed BITFIELD approach
go run ./cmd/seed --mode=bitfield --seats=100000 --valkey-addr=$VALKEY_ADDR
```

## 7. Run load tests

```bash
# HSET test (saves results/hset-run.csv)
make test-hset VALKEY_ADDR=$VALKEY_ADDR

# BITFIELD test (saves results/bitfield-run.csv)
make test-bitfield VALKEY_ADDR=$VALKEY_ADDR
```

## 8. Grafana (on poc-loadgen node)

```bash
docker run -d --name grafana \
  -p 3000:3000 \
  -v grafana-data:/var/lib/grafana \
  grafana/grafana:11.0.0

# Import dashboard
curl -X POST http://admin:admin@localhost:3000/api/dashboards/import \
  -H "Content-Type: application/json" \
  -d "{\"dashboard\": $(cat grafana/dashboard.json), \"overwrite\": true}"
```

Access Grafana at `http://LOADGEN_IP:3000` (admin/admin).

Add Prometheus datasource pointing to `http://localhost:9090`.

## 9. Teardown

```bash
gcloud compute instances delete poc-valkey poc-loadgen --zone=us-central1-a --quiet
```
