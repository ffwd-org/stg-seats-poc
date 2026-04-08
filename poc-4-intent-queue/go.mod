module github.com/ffwd-org/stg-seats-poc/poc-4-intent-queue

go 1.24.9

require (
	github.com/joho/godotenv v1.5.1
	github.com/nats-io/nats.go v1.36.0
	github.com/prometheus/client_golang v1.20.5
	github.com/twmb/franz-go v1.17.0
	github.com/valkey-io/valkey-go v1.0.73
)

require (
	github.com/beorn7/perks v1.0.1 // indirect
	github.com/cespare/xxhash/v2 v2.3.0 // indirect
	github.com/klauspost/compress v1.17.9 // indirect
	github.com/munnerz/goautoneg v0.0.0-20191010083416-a7dc8b61c822 // indirect
	github.com/nats-io/nkeys v0.4.7 // indirect
	github.com/nats-io/nuid v1.0.1 // indirect
	github.com/pierrec/lz4/v4 v4.1.21 // indirect
	github.com/prometheus/client_model v0.6.1 // indirect
	github.com/prometheus/common v0.55.0 // indirect
	github.com/prometheus/procfs v0.15.1 // indirect
	github.com/twmb/franz-go/pkg/kmsg v1.8.0 // indirect
	golang.org/x/crypto v0.23.0 // indirect
	golang.org/x/sys v0.39.0 // indirect
	golang.org/x/text v0.32.0 // indirect
	google.golang.org/protobuf v1.34.2 // indirect
)

replace github.com/ffwd-org/stg-seats-poc/pkg => ../pkg
