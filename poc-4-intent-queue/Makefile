.PHONY: help build redpanda nats valkey-streams direct all provision seed teardown

GCP_PROJECT ?= $(shell gcloud config get-value project 2>/dev/null)
GCP_ZONE    ?= us-central1-a
VALKEY_ADDR  ?= 10.142.0.xx
BROKER_ADDR  ?= 10.142.0.xx
RATE         ?= 10000
DURATION     ?= 120s
BATCH_SIZE   ?= 100
CONSUMERS    ?= 1

help:
	@echo "POC 4 — Intent Queue (Redpanda vs NATS vs Valkey Streams)"
	@echo ""
	@echo "  make build              Build all binaries"
	@echo "  make direct             Direct-to-Valkey baseline"
	@echo "  make redpanda           Redpanda queue path"
	@echo "  make nats               NATS JetStream path"
	@echo "  make valkey-streams     Valkey Streams path"
	@echo "  make all                Run all 4 tests sequentially"
	@echo ""
	@echo "  make provision          Provision GCP VMs"
	@echo "  make seed               Seed 100K seats in Valkey"
	@echo "  make teardown           Tear down all VMs"

build:
	go build -o bin/producer ./cmd/producer
	go build -o bin/consumer ./cmd/consumer
	go build -o bin/direct   ./cmd/direct

direct:
	@if [ "$(VALKEY_ADDR)" = "10.142.0.xx" ]; then echo "Set VALKEY_ADDR"; exit 1; fi
	go run ./cmd/direct --valkey-addr=$(VALKEY_ADDR)

redpanda:
	@if [ "$(BROKER_ADDR)" = "10.142.0.xx" ]; then echo "Set BROKER_ADDR"; exit 1; fi
	@if [ "$(VALKEY_ADDR)" = "10.142.0.xx" ]; then echo "Set VALKEY_ADDR"; exit 1; fi
	docker compose -f docker-compose.redpanda.yml up -d
	go run ./cmd/consumer --queue=redpanda --valkey-addr=$(VALKEY_ADDR) \
		--redpanda-brokers=$(BROKER_ADDR):9092 --batch-size=$(BATCH_SIZE) \
		--consumers=$(CONSUMERS) &
	sleep 2
	go run ./cmd/producer --queue=redpanda --rate=$(RATE) --duration=$(DURATION) \
		--redpanda-brokers=$(BROKER_ADDR):9092

nats:
	@if [ "$(BROKER_ADDR)" = "10.142.0.xx" ]; then echo "Set BROKER_ADDR"; exit 1; fi
	@if [ "$(VALKEY_ADDR)" = "10.142.0.xx" ]; then echo "Set VALKEY_ADDR"; exit 1; fi
	docker compose -f docker-compose.nats.yml up -d
	go run ./cmd/consumer --queue=nats --valkey-addr=$(VALKEY_ADDR) \
		--nats-url=nats://$(BROKER_ADDR):4222 --batch-size=$(BATCH_SIZE) \
		--consumers=$(CONSUMERS) &
	sleep 2
	go run ./cmd/producer --queue=nats --rate=$(RATE) --duration=$(DURATION) \
		--nats-url=nats://$(BROKER_ADDR):4222

valkey-streams:
	@if [ "$(VALKEY_ADDR)" = "10.142.0.xx" ]; then echo "Set VALKEY_ADDR"; exit 1; fi
	go run ./cmd/consumer --queue=valkey-streams --valkey-addr=$(VALKEY_ADDR) \
		--batch-size=$(BATCH_SIZE) --consumers=$(CONSUMERS) &
	sleep 2
	go run ./cmd/producer --queue=valkey-streams --rate=$(RATE) --duration=$(DURATION) \
		--valkey-addr=$(VALKEY_ADDR)

all: direct redpanda nats valkey-streams

provision:
	gcloud compute instances create poc-valkey \
		--zone=$(GCP_ZONE) --machine-type=c3-standard-8 \
		--image-family=ubuntu-2404-lts-amd64 --image-project=ubuntu-os-cloud \
		--network-tier=PREMIUM --provisioning-model=SPOT \
		--instance-termination-action=STOP \
		--labels=poc=stg-seats,cluster=a,pocnum=4
	gcloud compute instances create poc-loadgen \
		--zone=$(GCP_ZONE) --machine-type=c3-standard-8 \
		--image-family=ubuntu-2404-lts-amd64 --image-project=ubuntu-os-cloud \
		--network-tier=PREMIUM --provisioning-model=SPOT \
		--instance-termination-action=STOP \
		--labels=poc=stg-seats,cluster=a,pocnum=4
	gcloud compute instances create poc-broker \
		--zone=$(GCP_ZONE) --machine-type=c3-standard-4 \
		--image-family=ubuntu-2404-lts-amd64 --image-project=ubuntu-os-cloud \
		--network-tier=PREMIUM --provisioning-model=SPOT \
		--instance-termination-action=STOP \
		--labels=poc=stg-seats,cluster=a,pocnum=4

seed:
	@if [ "$(VALKEY_ADDR)" = "10.142.0.xx" ]; then echo "Set VALKEY_ADDR"; exit 1; fi
	go run ./cmd/seed --valkey-addr=$(VALKEY_ADDR)

teardown:
	gcloud compute instances delete poc-valkey poc-loadgen poc-broker \
		--zone=$(GCP_ZONE) --quiet 2>/dev/null || true
