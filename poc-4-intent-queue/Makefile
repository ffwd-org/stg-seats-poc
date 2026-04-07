.PHONY: help provision provision-broker seed test-direct test-redpanda test-nats test-valkey-streams teardown

GCP_PROJECT ?= $(shell gcloud config get-value project 2>/dev/null)
GCP_ZONE    ?= us-central1-a
VALKEY_ADDR  ?= 10.142.0.xx
BROKER_ADDR  ?= 10.142.0.xx

help:
	@echo "POC 4 — Intent Queue (Redpanda vs NATS vs Valkey Streams)"
	@echo "  make provision            Provision Cluster A + queue broker"
	@echo "  make seed                 Seed 100K seats in Valkey"
	@echo "  make test-direct          Direct-to-Valkey baseline"
	@echo "  make test-redpanda        Redpanda queue path"
	@echo "  make test-nats            NATS JetStream path"
	@echo "  make test-valkey-streams  Valkey Streams path"
	@echo "  make teardown             Tear down all VMs"

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

test-direct:
	@if [ "$(VALKEY_ADDR)" = "10.142.0.xx" ]; then echo "Set VALKEY_ADDR"; exit 1; fi
	go run ./cmd/producer --queue=direct --rate=10000 --duration=120s \
		--valkey-addr=$(VALKEY_ADDR)

test-redpanda:
	@if [ "$(BROKER_ADDR)" = "10.142.0.xx" ]; then echo "Set BROKER_ADDR"; exit 1; fi
	docker compose -f docker-compose.redpanda.yml up -d
	go run ./cmd/producer --queue=redpanda --rate=10000 --duration=120s \
		--redpanda-brokers=$(BROKER_ADDR):9092

test-nats:
	@if [ "$(BROKER_ADDR)" = "10.142.0.xx" ]; then echo "Set BROKER_ADDR"; exit 1; fi
	docker compose -f docker-compose.nats.yml up -d
	go run ./cmd/producer --queue=nats --rate=10000 --duration=120s \
		--nats-url=nats://$(BROKER_ADDR):4222

test-valkey-streams:
	@if [ "$(VALKEY_ADDR)" = "10.142.0.xx" ]; then echo "Set VALKEY_ADDR"; exit 1; fi
	go run ./cmd/producer --queue=valkey-streams --rate=10000 --duration=120s \
		--valkey-addr=$(VALKEY_ADDR)

teardown:
	gcloud compute instances delete poc-valkey poc-loadgen poc-broker \
		--zone=$(GCP_ZONE) --quiet 2>/dev/null || true
