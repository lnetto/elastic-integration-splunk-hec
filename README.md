# elastic-integration-splunk-hec

Elastic integration that collects and parses JSON events from Splunk's [HTTP Event Collector (HEC)](https://docs.splunk.com/Documentation/Splunk/latest/Data/UsetheHTTPEventCollector). Events can be delivered via [Splunk Ingest Actions](https://help.splunk.com/en/splunk-enterprise/forward-and-process-data/ingest-actions/use-ingest-actions-to-improve-the-data-input-process) (filestream or S3) or posted directly to an HTTP endpoint.

## How it works

Each incoming event is a Splunk HEC JSON envelope. The ingest pipeline:

1. Parses the envelope into `splunk.*` metadata fields (`host`, `source`, `sourcetype`, `index`, `time`)
2. Sets `@timestamp` from `splunk.time`
3. Promotes the raw log line (`splunk.event`) to `message` and `event.original`
4. Calculates `splunk.bytes` — the UTF-8 character length of the raw event, useful for estimating equivalent Splunk license consumption

## Repository layout

```
splunk_hec-0.1.0/          # Integration package (elastic-package format)
  data_stream/event/       # "event" data stream
    elasticsearch/         # Ingest pipeline
    fields/                # Field definitions
    agent/stream/          # Agent input templates (filestream, aws-s3, http_endpoint)
    _dev/test/pipeline/    # Pipeline unit tests
  docs/README.md           # Integration-level documentation
  manifest.yml             # Package manifest
deploy.sh                  # Build + install shortcut
test-event.sh              # Push a test event directly to Elasticsearch
```

## Prerequisites

- [`elastic-package`](https://github.com/elastic/elastic-package) on your PATH
- [`gh`](https://cli.github.com/) (GitHub CLI) for publishing releases
- A running Elastic Stack (local or cloud) with credentials in `.env`

## Environment setup

Create a `.env` file in the repo root (never committed):

```bash
ELASTIC_PACKAGE_ELASTICSEARCH_HOST=https://<your-cluster>:9200
ELASTIC_PACKAGE_ELASTICSEARCH_API_KEY=<your-api-key>
ELASTIC_PACKAGE_KIBANA_HOST=https://<your-cluster>:5601
```

## Building

```bash
cd splunk_hec-0.1.0
elastic-package build
```

The zip is written to `splunk_hec-0.1.0/build/packages/splunk_hec-0.1.0.zip`.

## Deploying locally

`deploy.sh` lints, builds, and installs the package in one step:

```bash
./deploy.sh
```

This runs:
1. `elastic-package lint` — validates the package spec
2. `elastic-package build` — produces the zip
3. `elastic-package install` — installs into the local stack

## Publishing a release to GitHub

After building:

```bash
gh release create v0.1.0 \
  splunk_hec-0.1.0/build/packages/splunk_hec-0.1.0.zip \
  --title "splunk_hec 0.1.0" \
  --notes "Initial release."
```

## Testing

**Pipeline unit tests** (no running cluster needed):

```bash
cd splunk_hec-0.1.0
elastic-package test pipeline
```

**End-to-end test** — indexes a sample HEC event and displays the processed document:

```bash
# Uses built-in sample event
./test-event.sh

# Supply your own HEC JSON
./test-event.sh '{"time":1700000000,"host":"myhost","sourcetype":"syslog","event":"hello world"}'
```

## Estimating Splunk license usage

Every processed event gets a `splunk.bytes` field. Summing it over a time window approximates what Splunk would count against a daily license.

Daily total in GB:

```esql
FROM logs-splunk_hec.*
| WHERE @timestamp >= NOW() - 1 day
| STATS total_bytes = SUM(splunk.bytes)
| EVAL total_gb = total_bytes / 1073741824
```

Broken down by sourcetype:

```esql
FROM logs-splunk_hec.*
| WHERE @timestamp >= NOW() - 1 day
| STATS daily_bytes = SUM(splunk.bytes) BY splunk.sourcetype
| EVAL daily_gb = daily_bytes / 1073741824
| SORT daily_bytes DESC
```

> `splunk.bytes` uses character count as a byte approximation. For typical ASCII log data this is equivalent; multibyte characters will be slightly undercounted.

## Fields

| Field | Type | Description |
|---|---|---|
| `@timestamp` | date | Event timestamp, derived from `splunk.time`. |
| `ecs.version` | keyword | ECS version. |
| `event.original` | keyword | Original log line from the source system. |
| `message` | keyword | Original log line, promoted for downstream parsing. |
| `splunk.bytes` | long | Character length of the raw event; approximates Splunk license byte consumption. |
| `splunk.host` | keyword | Splunk source host. |
| `splunk.index` | keyword | Destination Splunk index. |
| `splunk.source` | keyword | Splunk source name. |
| `splunk.sourcetype` | keyword | Splunk sourcetype. |
| `splunk.time` | long | Event timestamp as a Unix epoch. |
