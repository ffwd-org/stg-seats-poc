.PHONY: help provision start stop test teardown

GCP_PROJECT ?= $(shell gcloud config get-value project 2>/dev/null)
GCP_ZONE    ?= us-central1-a
CENTRIFUGO_IP ?= 10.142.0.xx
LOADGEN_IP  ?= 10.142.0.xx

help:
	@echo "POC 5 — Centrifugo Edge Offload"
	@echo "  make provision    Provision Cluster B"
	@echo "  make start         Start Centrifugo + Redis on app node"
	@echo "  make test          Run conngen + broadcaster"
	@echo "  make teardown      Tear down Cluster B"

provision:
	gcloud compute instances create poc-centrifugo \
		--zone=$(GCP_ZONE) --machine-type=m3-standard-8 \
		--image-family=ubuntu-2404-lts-amd64 --image-project=ubuntu-os-cloud \
		--network-tier=PREMIUM --provisioning-model=SPOT \
		--instance-termination-action=STOP \
		--labels=poc=stg-seats,cluster=b,pocnum=5
	gcloud compute instances create poc-loadgen \
		--zone=$(GCP_ZONE) --machine-type=c3-standard-8 \
		--image-family=ubuntu-2404-lts-amd64 --image-project=ubuntu-os-cloud \
		--network-tier=PREMIUM --provisioning-model=SPOT \
		--instance-termination-action=STOP \
		--labels=poc=stg-seats,cluster=b,pocnum=5

start:
	docker compose up -d
	@echo "Centrifugo running at http://$(CENTRIFUGO_IP):8000"

test:
	go run ./cmd/conngen \
		--target=ws://$(CENTRIFUGO_IP):8000/connection/uni_subscribe \
		--connections=250000 --ramp-rate=5000
	go run ./cmd/broadcaster \
		--target=http://$(CENTRIFUGO_IP):8000/api \
		--rate=100 --duration=120s

teardown:
	gcloud compute instances delete poc-centrifugo poc-loadgen \
		--zone=$(GCP_ZONE) --quiet 2>/dev/null || true
