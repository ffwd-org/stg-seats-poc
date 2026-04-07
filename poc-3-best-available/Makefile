.PHONY: help provision seed test test-best-available test-random teardown

GCP_PROJECT ?= $(shell gcloud config get-value project 2>/dev/null)
GCP_ZONE    ?= us-central1-a
VALKEY_ADDR ?= 10.142.0.xx

help:
	@echo "POC 3 — Best Available Lua Search"
	@echo "  make provision            Provision Cluster A"
	@echo "  VALKEY_ADDR=x.x.x.x make seed              Seed 100K-seat venue"
	@echo "  VALKEY_ADDR=x.x.x.x make test-best-available  Run best-available test"
	@echo "  VALKEY_ADDR=x.x.x.x make test-random        Run random baseline test"
	@echo "  make teardown             Tear down VMs"

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

seed:
	@if [ "$(VALKEY_ADDR)" = "10.142.0.xx" ]; then echo "Set VALKEY_ADDR"; exit 1; fi
	go run ./cmd/seed --mode=both --fragmentation=0 --valkey-addr=$(VALKEY_ADDR)

seed-50pct:
	@if [ "$(VALKEY_ADDR)" = "10.142.0.xx" ]; then echo "Set VALKEY_ADDR"; exit 1; fi
	go run ./cmd/seed --mode=both --fragmentation=50 --valkey-addr=$(VALKEY_ADDR)

test-best-available:
	@if [ "$(VALKEY_ADDR)" = "10.142.0.xx" ]; then echo "Set VALKEY_ADDR"; exit 1; fi
	go run ./cmd/loadgen --mode=best-available --workers=1000 \
		--quantity=2 --section=* --stage-duration=60s \
		--valkey-addr=$(VALKEY_ADDR)

test-random:
	@if [ "$(VALKEY_ADDR)" = "10.142.0.xx" ]; then echo "Set VALKEY_ADDR"; exit 1; fi
	go run ./cmd/loadgen --mode=random --workers=1000 \
		--quantity=2 --section=* --stage-duration=60s \
		--valkey-addr=$(VALKEY_ADDR)

teardown:
	gcloud compute instances delete poc-valkey poc-loadgen \
		--zone=$(GCP_ZONE) --quiet 2>/dev/null || true
