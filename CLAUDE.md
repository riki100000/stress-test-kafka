# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A Kafka cluster stress-testing harness written in Go. It boots a 3-node Kafka cluster in **KRaft mode** (no Zookeeper) via `docker compose`, then drives it with two Go producers (`main.go` for full load, `main-quick-test.go` for smoke tests). The two `.go` files are independent `package main` entry points — they are never compiled together; the Makefile builds each into its own binary under `bin/`.

## Build & Run

All everyday operations go through the `Makefile`. The Makefile sets `GOPROXY=https://goproxy.cn,direct` automatically; the `.envrc` mirrors this for `direnv` users.

```bash
make help          # list all targets
make up            # start the 3-node Kafka cluster + Kafka UI (port 8080)
make down          # stop cluster (keeps data volumes)
make down-clean    # stop + remove data volumes
make create-topic  # create stress-test-topic (3 partitions, replication-factor 3)
make quick-test    # build main-quick-test.go and send 10K messages
make run           # build main.go and send 100M messages
make all           # up + create-topic + quick-test (full happy-path workflow)
```

Direct Go commands (rarely needed — prefer the Makefile so the right entry file is selected):

```bash
go build -o bin/stress-test main.go
go build -o bin/quick-test main-quick-test.go
go test -race ./...   # no tests currently exist, but use -race if adding any
```

## Architecture

### Producer (Go, `main.go`)

- Uses `github.com/IBM/sarama` **async** producer (`sarama.NewAsyncProducer`).
- `Producer.Return.Successes = false` — success channel is intentionally closed for throughput. Counters in `main.go` count *enqueued* messages on `producer.Input() <- msg`, not broker-confirmed deliveries. Errors are read from `producer.Errors()` in a goroutine. Do **not** flip `RequiredAcks` to `WaitForAll` or re-enable success returns without understanding the throughput trade-off — the file comments call this out explicitly.
- Snappy compression; `RequiredAcks = 1` (leader-only ack); batch flush at 10K messages or 100ms.
- Hardcoded constants at the top of `main.go` (`numGoroutines`, `msgsPerWorker`, `broker`, `topic`) — these are the knobs to tune. The README's quoted "1 billion / 100,000 goroutines" figures and the source code's comments drift; trust the constants in source, not the prose.

### Kafka cluster (`docker-compose.yml`)

- Three `confluentinc/cp-kafka:8.1.2` nodes acting as **both** controllers and brokers (KRaft combined mode).
- `KAFKA_CLUSTER_ID: M8dH9ZLUTLi8K3bH5kPnYg` is **identical across all 3 nodes and immutable after first boot**. Changing it requires `make down-clean` to wipe volumes — otherwise the cluster will refuse to start.
- Two listener planes per broker:
  - **Internal** (`PLAINTEXT://:9092`, advertised as `kafka-controller-N:9092`): used between brokers and from inside the docker network (e.g. Kafka UI, `docker exec` admin commands).
  - **External** (`EXTERNAL://:1909{2,4,6}`, advertised as `localhost:1909{2,4,6}`): used by the Go producer running on the host. Host code must connect via `localhost:19092` — the producer hardcodes this.
- Defaults set cluster-wide: `KAFKA_NUM_PARTITIONS=3`, `KAFKA_MIN_INSYNC_REPLICAS=2`, `KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR=3`.

### Topology in one picture

```
Host (Go producer) ──tcp:19092──> kafka-controller-1 ─┐
                                                      ├── (internal :9092 mesh)
                                  kafka-controller-2 ─┤
                                  kafka-controller-3 ─┘
Kafka UI (container) ──internal:9092──> brokers
```

## Editing notes specific to this repo

- `main.go` and `main-quick-test.go` both declare `package main` and `const broker`/`const topic`. They compile **separately** — never try to `go build ./...` at the repo root; it will fail with duplicate-symbol errors. Always specify the file: `go build main.go` or use the Makefile.
- The broker address `localhost:19092` is hardcoded in both `.go` files. If the docker-compose port mapping changes, update both.
- `disk-test` / `disk-compare` targets shell out to `fio` — install separately (`brew install fio` on macOS). Output files (`fio-*.txt`, `seq-*`, `rand-*`) are produced in the repo root and cleaned via `make disk-clean`.
