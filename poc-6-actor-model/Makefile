.PHONY: help elixir seed run compare deps start test provision teardown loadgen

GCP_PROJECT ?= $(shell gcloud config get-value project 2>/dev/null)
GCP_ZONE    ?= us-central1-a
ELIXIR_IP   ?= localhost
ELIXIR_PORT ?= 4000
WORKERS     ?= 1000
DURATION    ?= 120s
QUANTITY    ?= 2

help:
	@echo "POC 6 — Elixir/BEAM Actor Model"
	@echo ""
	@echo "  Spec Targets:"
	@echo "  make elixir         Build Elixir release (mix compile)"
	@echo "  make seed           Seed 100K seats across 20 sections"
	@echo "  make run            Start the Elixir app (Bandit on :4000)"
	@echo "  make compare        Run loadgen and write results CSV"
	@echo ""
	@echo "  Dev Targets:"
	@echo "  make deps           mix deps.get"
	@echo "  make start          iex -S mix (interactive)"
	@echo "  make test           Run loadgen against running Elixir node"
	@echo "  make loadgen        Build Go load generator"
	@echo "  make docker         Build and run via docker compose"
	@echo ""
	@echo "  Infra Targets:"
	@echo "  make provision      Provision GCP VMs"
	@echo "  make teardown       Tear down VMs"

# --- Spec targets ---

elixir: deps
	mix compile

seed:
	@curl -s -X POST http://$(ELIXIR_IP):$(ELIXIR_PORT)/seed \
		-H 'Content-Type: application/json' \
		-d '{"seats":100000,"sections":20,"fragmentation":0}' | tee /dev/stderr
	@echo ""

run: deps
	elixir --sname stg_seats -S mix run --no-halt

compare: loadgen seed
	./cmd/loadgen/loadgen \
		--target=http://$(ELIXIR_IP):$(ELIXIR_PORT) \
		--workers=$(WORKERS) \
		--duration=$(DURATION) \
		--quantity=$(QUANTITY)
	@echo "Results saved to results/elixir-actor.csv"

# --- Dev targets ---

deps:
	mix deps.get

start:
	iex -S mix

test:
	go run ./cmd/loadgen \
		--target=http://$(ELIXIR_IP):$(ELIXIR_PORT) \
		--workers=$(WORKERS) \
		--duration=$(DURATION) \
		--quantity=$(QUANTITY)

loadgen:
	cd cmd/loadgen && go build -o loadgen .

docker:
	docker compose up --build

# --- Infra targets ---

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

teardown:
	gcloud compute instances delete poc-elixir poc-loadgen \
		--zone=$(GCP_ZONE) --quiet 2>/dev/null || true
