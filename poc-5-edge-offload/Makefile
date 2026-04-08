.PHONY: help provision start stop test teardown centrifugo connect publish compare build

GCP_PROJECT ?= $(shell gcloud config get-value project 2>/dev/null)
GCP_ZONE    ?= us-central1-a
CENTRIFUGO_IP ?= 10.142.0.xx
LOADGEN_IP  ?= 10.142.0.xx
JWT_SECRET  ?= poc-secret-key-for-jwt
API_KEY     ?= poc-api-key
CHANNEL     ?= events:event-1

help:
	@echo "POC 5 — Centrifugo Edge Offload"
	@echo "  make provision    Provision Cluster B"
	@echo "  make start        Start Centrifugo + Redis on app node"
	@echo "  make centrifugo   Start Centrifugo stack (docker compose)"
	@echo "  make connect      Run conngen (250K WebSocket clients)"
	@echo "  make publish      Run broadcaster (publish to channel)"
	@echo "  make compare      Run full comparison test"
	@echo "  make test         Run conngen + broadcaster"
	@echo "  make build        Build all Go binaries"
	@echo "  make teardown     Tear down Cluster B"

build:
	go build -o bin/conngen ./cmd/conngen
	go build -o bin/gowspublisher ./cmd/gowspublisher
	go build -o bin/broadcaster ./cmd/broadcaster

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

centrifugo:
	docker compose up -d
	@echo "Centrifugo stack running (Centrifugo + Redis + Prometheus)"

connect:
	go run ./cmd/conngen \
		--target=ws://$(CENTRIFUGO_IP):8000/connection/websocket \
		--connections=250000 --ramp-rate=5000 \
		--jwt-secret=$(JWT_SECRET) --channel=$(CHANNEL)

publish:
	go run ./cmd/broadcaster \
		--target=http://$(CENTRIFUGO_IP):8000 \
		--api-key=$(API_KEY) --channel=$(CHANNEL) \
		--rate=100 --duration=120s

compare:
	@echo "=== Phase 1: Connect 250K clients ==="
	go run ./cmd/conngen \
		--target=ws://$(CENTRIFUGO_IP):8000/connection/websocket \
		--connections=250000 --ramp-rate=5000 \
		--jwt-secret=$(JWT_SECRET) --channel=$(CHANNEL) &
	@sleep 60
	@echo "=== Phase 2: Broadcast storm ==="
	go run ./cmd/broadcaster \
		--target=http://$(CENTRIFUGO_IP):8000 \
		--api-key=$(API_KEY) --channel=$(CHANNEL) \
		--rate=100 --duration=120s

test:
	go run ./cmd/conngen \
		--target=ws://$(CENTRIFUGO_IP):8000/connection/websocket \
		--connections=250000 --ramp-rate=5000 \
		--jwt-secret=$(JWT_SECRET) --channel=$(CHANNEL)
	go run ./cmd/broadcaster \
		--target=http://$(CENTRIFUGO_IP):8000 \
		--api-key=$(API_KEY) --channel=$(CHANNEL) \
		--rate=100 --duration=120s

teardown:
	gcloud compute instances delete poc-centrifugo poc-loadgen \
		--zone=$(GCP_ZONE) --quiet 2>/dev/null || true
