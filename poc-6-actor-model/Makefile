.PHONY: help provision deps start test test-phase-a test-phase-b teardown

GCP_PROJECT ?= $(shell gcloud config get-value project 2>/dev/null)
GCP_ZONE    ?= us-central1-a
ELIXIR_IP   ?= 10.142.0.xx

help:
	@echo "POC 6 — Elixir/BEAM Actor Model"
	@echo "  make provision     Provision Cluster C"
	@echo "  make deps           mix deps.get"
	@echo "  make start          iex -S mix"
	@echo "  make test           Run loadgen against running Elixir node"
	@echo "  make teardown       Tear down VMs"

provision:
	gcloud compute instances create poc-elixir \
		--zone=$(GCP_ZONE) --machine-type=c3-standard-8 \
		--image-family=ubuntu-2404-lts-amd64 --image-project=ubuntu-os-cloud \
		--network-tier=PREMIUM --provisioning-model=SPOT \
		--instance-termination-action=STOP \
		--labels=poc=stg-seats,cluster=c,pocnum=6
	gcloud compute instances create poc-loadgen \
		--zone=$(GCP_ZONE) --machine-type=c3-standard-4 \
		--image-family=ubuntu-2404-lts-amd64 --image-project=ubuntu-os-cloud \
		--network-tier=PREMIUM --provisioning-model=SPOT \
		--instance-termination-action=STOP \
		--labels=poc=stg-seats,cluster=c,pocnum=6

deps:
	mix deps.get
	mix deps.compile

start:
	iex -S mix

test:
	@if [ "$(ELIXIR_IP)" = "10.142.0.xx" ]; then echo "Set ELIXIR_IP"; exit 1; fi
	go run ./cmd/loadgen \
		--target=http://$(ELIXIR_IP):4000 \
		--workers=1000 \
		--duration=120s

teardown:
	gcloud compute instances delete poc-elixir poc-loadgen \
		--zone=$(GCP_ZONE) --quiet 2>/dev/null || true
