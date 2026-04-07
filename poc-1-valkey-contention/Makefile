.PHONY: help provision seed-hset seed-bitfield test-hset test-bitfield compare teardown

GCP_PROJECT ?= $(shell gcloud config get-value project 2>/dev/null)
GCP_ZONE    ?= us-central1-a
VALKEY_ADDR ?= 10.142.0.xx
LOADGEN_ADDR ?= 10.142.0.xx

help:
	@echo "POC 1 — Valkey Contention (HSET vs BITFIELD)"
	@echo ""
	@echo "  GCP_PROJECT=my-project make provision     Provision Cluster A VMs on GCP"
	@echo "  VALKEY_ADDR=x.x.x.x make seed-hset         Seed 100K seats as HSET"
	@echo "  VALKEY_ADDR=x.x.x.x make seed-bitfield     Seed 100K seats as BITFIELD"
	@echo "  VALKEY_ADDR=x.x.x.x make test-hset         Run load test in HSET mode"
	@echo "  VALKEY_ADDR=x.x.x.x make test-bitfield     Run load test in BITFIELD mode"
	@echo "  make compare                               Compare results/*.csv"
	@echo "  make teardown                              Tear down all POC VMs"
	@echo ""
	@echo "Environment variables:"
	@echo "  GCP_PROJECT   GCP project (auto-detected)"
	@echo "  GCP_ZONE      GCP zone (default: us-central1-a)"
	@echo "  VALKEY_ADDR   Internal IP of Valkey node"

# ── Provision ──────────────────────────────────────────────────────────────────

provision:
	@echo "Provisioning Cluster A — POC 1 Valkey Contention..."
	gcloud compute instances create poc-valkey \
		--zone=$(GCP_ZONE) \
		--machine-type=c3-standard-8 \
		--image-family=ubuntu-2404-lts-amd64 \
		--image-project=ubuntu-os-cloud \
		--network-tier=PREMIUM \
		--provisioning-model=SPOT \
		--instance-termination-action=STOP \
		--labels=poc=stg-seats,cluster=a,pocnum=1 \
		--quiet
	@echo "Waiting for valkey node to start..."
	sleep 5
	gcloud compute instances create poc-loadgen \
		--zone=$(GCP_ZONE) \
		--machine-type=c3-standard-8 \
		--image-family=ubuntu-2404-lts-amd64 \
		--image-project=ubuntu-os-cloud \
		--network-tier=PREMIUM \
		--provisioning-model=SPOT \
		--instance-termination-action=STOP \
		--labels=poc=stg-seats,cluster=a,pocnum=1 \
		--quiet
	@echo "Cluster A provisioned. Fetching internal IPs..."
	@echo "  VALKEY_ADDR=$$(gcloud compute instances describe poc-valkey --zone=$(GCP_ZONE) --format='get(networkInterfaces[0].networkIP)')"
	@echo "  LOADGEN_ADDR=$$(gcloud compute instances describe poc-loadgen --zone=$(GCP_ZONE) --format='get(networkInterfaces[0].networkIP)')"

# ── Seed ───────────────────────────────────────────────────────────────────────

seed-hset:
	@if [ "$(VALKEY_ADDR)" = "10.142.0.xx" ]; then echo "ERROR: set VALKEY_ADDR"; exit 1; fi
	go run ./cmd/seed --mode=hset --seats=100000 --valkey-addr=$(VALKEY_ADDR)

seed-bitfield:
	@if [ "$(VALKEY_ADDR)" = "10.142.0.xx" ]; then echo "ERROR: set VALKEY_ADDR"; exit 1; fi
	go run ./cmd/seed --mode=bitfield --seats=100000 --valkey-addr=$(VALKEY_ADDR)

seed-both:
	@if [ "$(VALKEY_ADDR)" = "10.142.0.xx" ]; then echo "ERROR: set VALKEY_ADDR"; exit 1; fi
	go run ./cmd/seed --mode=both --seats=100000 --valkey-addr=$(VALKEY_ADDR)

# ── Test ───────────────────────────────────────────────────────────────────────

METRICS_PORT := 2112

test-hset: METRICS_PORT=2112
test-hset:
	@if [ "$(VALKEY_ADDR)" = "10.142.0.xx" ]; then echo "ERROR: set VALKEY_ADDR"; exit 1; fi
	mkdir -p results && \
	go run ./cmd/loadgen \
		--mode=hset \
		--valkey-addr=$(VALKEY_ADDR) \
		--ramp=100,1000,5000,10000,25000,50000,100000 \
		--stage-duration=60s \
		--cooldown=10s \
		--metrics-port=$(METRICS_PORT) \
		2>&1 | tee results/hset-run.log

test-bitfield: METRICS_PORT=2112
test-bitfield:
	@if [ "$(VALKEY_ADDR)" = "10.142.0.xx" ]; then echo "ERROR: set VALKEY_ADDR"; exit 1; fi
	mkdir -p results && \
	go run ./cmd/loadgen \
		--mode=bitfield \
		--valkey-addr=$(VALKEY_ADDR) \
		--ramp=100,1000,5000,10000,25000,50000,100000 \
		--stage-duration=60s \
		--cooldown=10s \
		--metrics-port=$(METRICS_PORT) \
		2>&1 | tee results/bitfield-run.log

# ── Compare ────────────────────────────────────────────────────────────────────

compare:
	@echo "=== POC 1 Results Comparison ==="
	@if [ -f results/hset-run.csv ]; then \
		echo "--- HSET ---"; \
		cat results/hset-run.csv; \
	else \
		echo "No HSET results found"; \
	fi
	@echo ""
	@if [ -f results/bitfield-run.csv ]; then \
		echo "--- BITFIELD ---"; \
		cat results/bitfield-run.csv; \
	else \
		echo "No BITFIELD results found"; \
	fi

# ── Teardown ───────────────────────────────────────────────────────────────────

teardown:
	gcloud compute instances delete poc-valkey --zone=$(GCP_ZONE) --quiet 2>/dev/null || true
	gcloud compute instances delete poc-loadgen --zone=$(GCP_ZONE) --quiet 2>/dev/null || true
	@echo "Cluster A torn down."
