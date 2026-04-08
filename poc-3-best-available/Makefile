.PHONY: help provision seed seed-f0 seed-f25 seed-f50 seed-f80 run test-best-available test-random teardown all

GCP_PROJECT ?= $(shell gcloud config get-value project 2>/dev/null)
GCP_ZONE    ?= us-central1-a
VALKEY_ADDR ?= localhost:6379

help:
	@echo "POC 3 — Best Available Lua Search"
	@echo ""
	@echo "  make run                             Start local Valkey via docker-compose"
	@echo "  make seed-f0                         Seed 100K-seat venue (0% fragmentation)"
	@echo "  make seed-f25                        Seed with 25% fragmentation"
	@echo "  make seed-f50                        Seed with 50% fragmentation"
	@echo "  make seed-f80                        Seed with 80% fragmentation"
	@echo "  make test-best-available             Run best-available test"
	@echo "  make test-random                     Run random baseline test"
	@echo "  make all                             run + seed-f0 + test-best-available"
	@echo "  make provision                       Provision GCP Cluster A"
	@echo "  make teardown                        Tear down VMs"

run:
	docker compose up -d

seed: seed-f0

seed-f0:
	go run ./cmd/seed --mode=both --fragmentation=0 --valkey-addr=$(VALKEY_ADDR)

seed-f25:
	go run ./cmd/seed --mode=both --fragmentation=25 --valkey-addr=$(VALKEY_ADDR)

seed-f50:
	go run ./cmd/seed --mode=both --fragmentation=50 --valkey-addr=$(VALKEY_ADDR)

seed-f80:
	go run ./cmd/seed --mode=both --fragmentation=80 --valkey-addr=$(VALKEY_ADDR)

provision:
	gcloud compute instances create poc-valkey \
		--zone=$(GCP_ZONE) --machine-type=c3-standard-8 \
		--image-family=ubuntu-2404-lts-amd64 --image-project=ubuntu-os-cloud \
		--network-tier=PREMIUM --provisioning-model=SPOT \
		--instance-termination-action=STOP \
		--labels=poc=stg-seats,cluster=a,pocnum=3
	gcloud compute instances create poc-loadgen \
		--zone=$(GCP_ZONE) --machine-type=c3-standard-8 \
		--image-family=ubuntu-2404-lts-amd64 --image-project=ubuntu-os-cloud \
		--network-tier=PREMIUM --provisioning-model=SPOT \
		--instance-termination-action=STOP \
		--labels=poc=stg-seats,cluster=a,pocnum=3

test-best-available:
	go run ./cmd/loadgen --mode=best-available --workers=1000 \
		--quantity=2 --section=* --duration=60s \
		--valkey-addr=$(VALKEY_ADDR)

test-random:
	go run ./cmd/loadgen --mode=random --workers=1000 \
		--quantity=2 --section=* --duration=60s \
		--valkey-addr=$(VALKEY_ADDR)

all: run seed-f0 test-best-available

teardown:
	gcloud compute instances delete poc-valkey poc-loadgen \
		--zone=$(GCP_ZONE) --quiet 2>/dev/null || true
