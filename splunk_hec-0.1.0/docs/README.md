# Splunk HEC

Collects and parses JSON events from Splunk's [HTTP Event Collector (HEC)](https://docs.splunk.com/Documentation/Splunk/latest/Data/UsetheHTTPEventCollector). Events can be delivered via [Splunk Ingest Actions](https://help.splunk.com/en/splunk-enterprise/forward-and-process-data/ingest-actions/use-ingest-actions-to-improve-the-data-input-process) (filestream or S3) or posted directly to the HTTP endpoint.

## How it works

Each incoming event is a Splunk HEC JSON envelope. The integration pipeline:
 
1. Parses the envelope into `splunk.*` metadata fields (`host`, `source`, `sourcetype`, `index`, `time`)
2. Sets `@timestamp` from `splunk.time`
3. Promotes the raw log line (`splunk.event`) to the standard `message` field and `event.original`

The result is a document with the Splunk metadata preserved under `splunk.*` and the original log line ready for further parsing in `message`.

## Estimating Splunk license usage

Every event gets a `splunk.bytes` field containing the UTF-8 byte length of the raw log line. Summing this over a time window gives a rough equivalent of what Splunk would count against a daily license.

Example Lens / ES|QL query for daily GB ingested:

```esql
FROM logs-splunk_hec.*
| WHERE @timestamp >= NOW() - 1 day
| STATS total_bytes = SUM(splunk.bytes)
| EVAL total_gb = total_bytes / 1073741824
```

Or broken down by sourcetype to see which data sources drive the most volume:

```esql
FROM logs-splunk_hec.*
| WHERE @timestamp >= NOW() - 1 day
| STATS daily_bytes = SUM(splunk.bytes) BY splunk.sourcetype
| EVAL daily_gb = daily_bytes / 1073741824
| SORT daily_bytes DESC
```

> **Note:** `splunk.bytes` is a character count, not a true byte count — multibyte characters will be undercounted. For typical ASCII log data (syslog, firewall events, etc.) character count and byte count are equivalent.
## Example event

```json
{
  "@timestamp": "2026-05-20T12:50:32.000Z",
  "ecs": {
    "version": "9.3.0"
  },
  "event": {
    "original": "2026-05-20T12:50:33Z foobar"
  },
  "message": "2026-05-20T12:50:33Z foobar",
  "splunk": {
    "host": "my_host",
    "index": "my_index",
    "source": "my_source",
    "sourcetype": "my_sourcetype",
    "time": 1779281432
  }
}
```

<details>
<summary>Exported fields</summary>

| Field | Type | Description |
|-------|------|-------------|
| @timestamp | date | Event timestamp, from `splunk.time`. |
| ecs.version | keyword | ECS version. |
| event.original | keyword | The original log line from the source system. |
| message | keyword | The original log line, promoted for downstream parsing. |
| splunk.bytes | long | Character length of the raw event, used as a byte approximation. Sum over a time range to approximate equivalent Splunk license consumption. |
| splunk.host | keyword | The Splunk source host. |
| splunk.index | keyword | The destination Splunk index. |
| splunk.source | keyword | The Splunk source name. |
| splunk.sourcetype | keyword | The Splunk sourcetype. |
| splunk.time | long | The event timestamp as a Unix epoch. |

</details>
