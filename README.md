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

## Routing events by sourcetype

You can fan events out to sourcetype-specific integrations using a [`reroute` processor](https://www.elastic.co/guide/en/elasticsearch/reference/current/reroute-processor.html). There are two patterns depending on whether your inputs are mixed or dedicated.

### Shared parsing pipeline

The HEC envelope parsing logic lives in a standalone pipeline — `splunk_hec-parse-envelope` — that is called by the integration's built-in pipeline. Any per-sourcetype custom pipeline can call the same shared pipeline, so the parsing logic stays in one place.

Import it before using either pattern below:

```bash
curl -X PUT "${ELASTIC_PACKAGE_ELASTICSEARCH_HOST}/_ingest/pipeline/splunk_hec-parse-envelope" \
  -H "Authorization: ApiKey ${ELASTIC_PACKAGE_ELASTICSEARCH_API_KEY}" \
  -H "Content-Type: application/json" \
  -d @pipelines/splunk_hec-parse-envelope.json
```

---

### Pattern A — mixed stream with `@custom` pipeline

Use this when a single input receives events from multiple sourcetypes (e.g. one S3 bucket, one HTTP endpoint). All events land in `logs-splunk_hec.event-default`, the integration parses them, then `@custom` reroutes by sourcetype.

```
Agent input (any sourcetype mixed)
  → logs-splunk_hec.event-default
      └─ splunk_hec-parse-envelope        ← parsing
  → logs-splunk_hec.event@custom          ← reroute by if/sourcetype
  → logs-cisco_asa.log-default            ← Cisco ASA integration runs
```

A ready-to-use template is at [`pipelines/logs-splunk_hec.event@custom.json`](pipelines/logs-splunk_hec.event@custom.json). Edit the sourcetype conditions to match your environment, then import it:

```bash
curl -X PUT "${ELASTIC_PACKAGE_ELASTICSEARCH_HOST}/_ingest/pipeline/logs-splunk_hec.event%40custom" \
  -H "Authorization: ApiKey ${ELASTIC_PACKAGE_ELASTICSEARCH_API_KEY}" \
  -H "Content-Type: application/json" \
  -d @pipelines/logs-splunk_hec.event@custom.json
```

Example processors inside `logs-splunk_hec.event@custom`:

```yaml
- reroute:
    tag: reroute_cisco_asa
    if: ctx.splunk?.sourcetype == "cisco:asa"
    dataset: cisco_asa.log

- reroute:
    tag: reroute_palo_alto
    if: ctx.splunk?.sourcetype == "pan:traffic"
    dataset: panw.panos
```

Events that don't match any rule stay in `logs-splunk_hec.event-default` unchanged.

---

### Pattern B — dedicated stream per sourcetype

Use this when you have a dedicated input per sourcetype (e.g. a filestream that only collects Cisco ASA logs). Set `data_stream.dataset` in the Elastic Agent policy to a unique value for that input. The per-sourcetype `@custom` pipeline calls the shared parser then reroutes unconditionally — no `if` conditions needed.

```
Agent input (data_stream.dataset: splunk_hec.cisco_asa)
  → logs-splunk_hec.cisco_asa-default
  → logs-splunk_hec.cisco_asa@custom
      ├─ splunk_hec-parse-envelope        ← shared parsing
      └─ reroute → cisco_asa.log          ← unconditional
  → logs-cisco_asa.log-default            ← Cisco ASA integration runs
```

A ready-to-use template for this is at [`pipelines/logs-splunk_hec.cisco_asa@custom.json`](pipelines/logs-splunk_hec.cisco_asa@custom.json):

```bash
curl -X PUT "${ELASTIC_PACKAGE_ELASTICSEARCH_HOST}/_ingest/pipeline/logs-splunk_hec.cisco_asa%40custom" \
  -H "Authorization: ApiKey ${ELASTIC_PACKAGE_ELASTICSEARCH_API_KEY}" \
  -H "Content-Type: application/json" \
  -d @pipelines/logs-splunk_hec.cisco_asa@custom.json
```

Copy and adapt this file for each additional sourcetype.

---

### How the target pipeline is resolved

When Elasticsearch receives a document in `logs-cisco_asa.log-default` it automatically runs the pipeline registered for that index template — so the Cisco ASA integration's own ingest pipeline processes the event without any extra configuration. The `splunk.*` fields and `message` are already set, so the sourcetype-specific pipeline sees the plain log line and can parse it normally.

### Prerequisites

- `splunk_hec-parse-envelope` must be imported before the integration or any custom pipeline is used
- The target integration (e.g. Cisco ASA) must be installed in Kibana — if its index template or pipeline doesn't exist, Elasticsearch will reject rerouted documents

> **Kibana UI alternative:** all pipelines in the `pipelines/` directory can also be imported via **Stack Management → Ingest Pipelines → Create pipeline → Load from JSON**.

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
