VALKEY_ADDR ?= 10.10.10.10:6379
GCP_PROJECT ?= your-project-id
GCP_ZONE    ?= us-central1-a

.PHONY: provision seed-hset seed-bitfield test-hset test-bitfield teardown

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

seed-hset:
	go run ./cmd/seed --mode=hset --seats=100000 --valkey-addr=$(VALKEY_ADDR)

seed-bitfield:
	go run ./cmd/seed --mode=bitfield --seats=100000 --valkey-addr=$(VALKEY_ADDR)

test-hset:
	go run ./cmd/loadgen --mode=hset \
	  --ramp=100,1000,5000,10000,25000,50000,100000 \
	  --stage-duration=60s --cooldown=10s \
	  --valkey-addr=$(VALKEY_ADDR) --metrics-port=2112

test-bitfield:
	go run ./cmd/loadgen --mode=bitfield \
	  --ramp=100,1000,5000,10000,25000,50000,100000 \
	  --stage-duration=60s --cooldown=10s \
	  --valkey-addr=$(VALKEY_ADDR) --metrics-port=2112

teardown:
	gcloud compute instances delete poc-valkey poc-loadgen \
	  --zone=$(GCP_ZONE) --quiet
