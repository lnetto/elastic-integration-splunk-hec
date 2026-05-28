#!/bin/bash
# test-event.sh — push a test Splunk HEC event directly to Elasticsearch
# Usage:
#   ./test-event.sh                          # use built-in sample event
#   ./test-event.sh '{"time":...,"event":…}' # supply your own HEC JSON

set -euo pipefail
source .env

INDEX="logs-splunk_hec.event-default"
AUTH=(-H "Authorization: ApiKey $ELASTIC_PACKAGE_ELASTICSEARCH_API_KEY")
JSON=(-H "Content-Type: application/json")

# ---------------------------------------------------------------------------
# 1. Build the event — use arg if provided, otherwise the built-in sample
# ---------------------------------------------------------------------------
if [[ $# -gt 0 ]]; then
  HEC_JSON="$1"
else
  TS=$(date +%s)
  HEC_JSON=$(printf '{"time":%d,"host":"test-host","source":"/var/log/syslog","sourcetype":"syslog","index":"main","event":"test event from test-event.sh at %s"}' \
    "$TS" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')")
fi

# Wrap the HEC JSON as a string in the "message" field (what the Agent writes)
BODY=$(printf '{"message": %s}' "$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$HEC_JSON")")

# ---------------------------------------------------------------------------
# 3. Index the document
# ---------------------------------------------------------------------------
echo ""
echo "📨  Indexing event..."
RESPONSE=$(curl -s -X POST "${AUTH[@]}" "${JSON[@]}" \
  "$ELASTIC_PACKAGE_ELASTICSEARCH_HOST/$INDEX/_doc?refresh=true" \
  -d "$BODY")

DOC_ID=$(echo "$RESPONSE" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('_id',''))" 2>/dev/null)
RESULT=$(echo "$RESPONSE"  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('result',''))" 2>/dev/null)

if [[ "$RESULT" != "created" ]]; then
  echo "❌  Index failed:"
  echo "$RESPONSE" | python3 -m json.tool
  exit 1
fi
echo "✅  Indexed as $DOC_ID"

# ---------------------------------------------------------------------------
# 4. Fetch and display the processed document (retry until visible)
# ---------------------------------------------------------------------------
echo ""
echo "⏳  Fetching processed document..."

RAW=""
for i in 1 2 3 4 5; do
  sleep 1
  RAW=$(curl -s -X POST "${AUTH[@]}" "${JSON[@]}" \
    "$ELASTIC_PACKAGE_ELASTICSEARCH_HOST/$INDEX/_search" \
    -d "{\"query\":{\"ids\":{\"values\":[\"$DOC_ID\"]}},\"size\":1}")
  HITS=$(echo "$RAW" | python3 -c "import json,sys; print(json.load(sys.stdin)['hits']['total']['value'])" 2>/dev/null)
  [[ "$HITS" == "1" ]] && break
  echo "   (waiting for doc to be visible, attempt $i/5...)"
done

echo "$RAW" | python3 -c "
import json, sys
d = json.load(sys.stdin)
hits = d['hits']['hits']
if not hits:
    print('❌  Document not found after retries.')
    sys.exit(1)
src = hits[0]['_source']
print()
print('─' * 60)
print(f'  @timestamp   : {src.get(\"@timestamp\",\"(missing)\")}')
print(f'  message      : {src.get(\"message\",\"(missing)\")}')
print(f'  bytes        : {src.get(\"splunk\",{}).get(\"bytes\",\"(missing)\")}')
print(f'  sourcetype   : {src.get(\"splunk\",{}).get(\"sourcetype\",\"(missing)\")}')
print(f'  host         : {src.get(\"splunk\",{}).get(\"host\",\"(missing)\")}')
print(f'  source       : {src.get(\"splunk\",{}).get(\"source\",\"(missing)\")}')
print(f'  index        : {src.get(\"splunk\",{}).get(\"index\",\"(missing)\")}')
print(f'  pipeline err : {src.get(\"event\",{}).get(\"kind\",\"ok\")}')
print('─' * 60)
print()
print('Full _source:')
print(json.dumps(src, indent=2))
"
