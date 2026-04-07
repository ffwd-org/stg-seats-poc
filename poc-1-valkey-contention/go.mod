module github.com/ffwd-org/stg-seats-poc/poc-1-valkey-contention

go 1.24

require (
	github.com/ffwd-org/stg-seats-poc v0.0.0
	github.com/joho/godotenv v1.5.1
	github.com/prometheus/client_golang v1.20.5
	github.com/valkey-io/valkey-go v1.0.73
)

replace github.com/ffwd-org/stg-seats-poc => ../
