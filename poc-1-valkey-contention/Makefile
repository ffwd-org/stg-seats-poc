VALKEY_ADDR ?= 10.10.10.10:6379
GCP_PROJECT ?= your-project-id
GCP_ZONE    ?= us-central1-a

.PHONY: provision seed run-hset run-bitfield compare teardown seed-hset seed-bitfield test-hset test-bitfield

provision:
	gcloud compute instances create poc-valkey \
	  --zone=$(GCP_ZONE) --machine-type=c3-standard-8 \
	  --image-family=ubuntu-2404-lts-amd64 --image-project=ubuntu-os-cloud \
	  --network-tier=PREMIUM --provisioning-model=SPOT \
	  --labels=poc=stg-seats,cluster=a
	gcloud compute instances create poc-loadgen \
	  --zone=$(GCP_ZONE) --machine-type=c3-standard-8 \
	  --image-family=ubuntu-2404-lts-amd64 --image-project=ubuntu-os-cloud \
	  --network-tier=PREMIUM --provisioning-model=SPOT \
	  --labels=poc=stg-seats,cluster=a

# --- Spec-compliant targets ---

seed:
	go run ./cmd/seed --mode=both --seats=100000 --valkey-addr=$(VALKEY_ADDR)

run-hset:
	go run ./cmd/loadgen --mode=hset \
	  --ramp=100,1000,5000,10000,25000,50000,100000 \
	  --duration=60s --cooldown=10s \
	  --valkey-addr=$(VALKEY_ADDR) --metrics-port=2112

run-bitfield:
	go run ./cmd/loadgen --mode=bitfield \
	  --ramp=100,1000,5000,10000,25000,50000,100000 \
	  --duration=60s --cooldown=10s \
	  --valkey-addr=$(VALKEY_ADDR) --metrics-port=2112

compare:
	@echo "=== HSET vs BITFIELD Comparison ==="
	@echo ""
	@if [ -f results/hset-run.csv ] && [ -f results/bitfield-run.csv ]; then \
		echo "--- HSET results ---"; \
		cat results/hset-run.csv; \
		echo ""; \
		echo "--- BITFIELD results ---"; \
		cat results/bitfield-run.csv; \
	else \
		echo "Missing result CSVs. Run 'make run-hset' and 'make run-bitfield' first."; \
	fi

# --- Legacy aliases (kept for backwards compatibility) ---

seed-hset:
	go run ./cmd/seed --mode=hset --seats=100000 --valkey-addr=$(VALKEY_ADDR)

seed-bitfield:
	go run ./cmd/seed --mode=bitfield --seats=100000 --valkey-addr=$(VALKEY_ADDR)

test-hset: run-hset

test-bitfield: run-bitfield

teardown:
	gcloud compute instances delete poc-valkey poc-loadgen \
	  --zone=$(GCP_ZONE) --quiet
