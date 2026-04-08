.PHONY: help server connect broadcast all provision seed test test-phase-a test-phase-b test-phase-c teardown

GCP_PROJECT ?= $(shell gcloud config get-value project 2>/dev/null)
GCP_ZONE    ?= us-central1-a
WS_IP       ?= 10.142.0.xx
LOADGEN_IP  ?= 10.142.0.xx

help:
	@echo "POC 2 — Go WebSocket Fan-out"
	@echo ""
	@echo "  make server                 Build & run the WebSocket server"
	@echo "  make connect                Build & run the connection generator"
	@echo "  make broadcast              Build & run the broadcaster"
	@echo "  make all                    Build all binaries"
	@echo ""
	@echo "  make provision              Provision Cluster B (m3-standard-8 WS + c3-standard-8 loadgen)"
	@echo "  WS_IP=x.x.x.x make test    Run all phases on a running server"
	@echo "  make teardown               Tear down Cluster B VMs"

server:
	go build -o bin/wsserver ./cmd/wsserver
	./bin/wsserver --port=8080 --metrics-port=2112

connect:
	go build -o bin/conngen ./cmd/conngen
	./bin/conngen --target=ws://$(WS_IP):8080/ws/event/1 --connections=250000 --ramp-rate=5000 --metrics-port=2113

broadcast:
	go build -o bin/broadcaster ./cmd/broadcaster
	./bin/broadcaster --target=http://$(WS_IP):8080/broadcast/1 --rate=1 --duration=30s

all:
	go build -o bin/wsserver ./cmd/wsserver
	go build -o bin/conngen ./cmd/conngen
	go build -o bin/broadcaster ./cmd/broadcaster

provision:
	gcloud compute instances create poc-wsserver \
		--zone=$(GCP_ZONE) \
		--machine-type=m3-standard-8 \
		--image-family=ubuntu-2404-lts-amd64 \
		--image-project=ubuntu-os-cloud \
		--network-tier=PREMIUM \
		--provisioning-model=SPOT \
		--instance-termination-action=STOP \
		--labels=poc=stg-seats,cluster=b,pocnum=2
	gcloud compute instances create poc-loadgen \
		--zone=$(GCP_ZONE) \
		--machine-type=c3-standard-8 \
		--image-family=ubuntu-2404-lts-amd64 \
		--image-project=ubuntu-os-cloud \
		--network-tier=PREMIUM \
		--provisioning-model=SPOT \
		--instance-termination-action=STOP \
		--labels=poc=stg-seats,cluster=b,pocnum=2
	@echo "Cluster B provisioned."
	@echo "  WS_IP=$$(gcloud compute instances describe poc-wsserver --zone=$(GCP_ZONE) --format='get(networkInterfaces[0].networkIP)')"
	@echo "  LOADGEN_IP=$$(gcloud compute instances describe poc-loadgen --zone=$(GCP_ZONE) --format='get(networkInterfaces[0].networkIP)')"

# Phase A: Idle connection ramp (10K → 250K, 60s idle each)
test-phase-a: WS_IP=localhost
test-phase-a:
	go run ./cmd/wsserver --port=8080 --metrics-port=2112 &
	WS_PID=$$!
	sleep 2
	go run ./cmd/conngen --target=ws://$(WS_IP):8080/ws/event/1 \
		--connections=10000 --ramp-rate=5000 --metrics-port=2113
	kill $$WS_PID 2>/dev/null

# Phase B: Single broadcast at 250K connections
test-phase-b:
	go run ./cmd/broadcaster --target=http://$(WS_IP):8080/broadcast/1 \
		--rate=1 --duration=30s --payload='{"seat":"42","status":"held"}'

# Phase C: Sustained broadcast storm
test-phase-c:
	go run ./cmd/broadcaster --target=http://$(WS_IP):8080/broadcast/1 \
		--rate=100 --duration=120s

test: test-phase-a test-phase-b test-phase-c

teardown:
	gcloud compute instances delete poc-wsserver poc-loadgen \
		--zone=$(GCP_ZONE) --quiet 2>/dev/null || true
	@echo "Cluster B torn down."
