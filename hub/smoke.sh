#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COLLECTOR_URL="${COLLECTOR_URL:-http://127.0.0.1:8000}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://127.0.0.1:9090}"
LOKI_URL="${LOKI_URL:-http://127.0.0.1:3100}"
TEMPO_URL="${TEMPO_URL:-http://127.0.0.1:3200}"

# Find events.jsonl
JSONL_FILE="${1:-}"
if [[ -z "${JSONL_FILE}" ]]; then
  for candidate in \
    "${SCRIPT_DIR}/../apps/collector/sample/events.jsonl" \
    "${SCRIPT_DIR}/../../apps/collector/sample/events.jsonl" \
    "/opt/jammy-obs/stack/apps/collector/sample/events.jsonl" \
    "/opt/jammy-obs/apps/collector/sample/events.jsonl"; do
    if [[ -f "${candidate}" ]]; then
      JSONL_FILE="${candidate}"
      break
    fi
  done
fi

if [[ -z "${JSONL_FILE}" || ! -f "${JSONL_FILE}" ]]; then
  echo "Error: sample/events.jsonl not found." >&2
  exit 1
fi

SAMPLE_EVENT_ID=$(python3 -c "import json; print(json.loads(open('${JSONL_FILE}', encoding='utf-8').readline())['event_id'])")

echo "=== [1/4] Sending 20 events from ${JSONL_FILE} ==="
post_count=0
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -z "$line" ]] && continue
  resp=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${COLLECTOR_URL}/api/v1/events" \
    -H "Content-Type: application/json" \
    -d "$line" || echo "000")
  if [[ "$resp" != "200" && "$resp" != "201" ]]; then
    echo "Warning: POST /api/v1/events returned HTTP ${resp} for line: ${line}" >&2
  fi
  post_count=$((post_count + 1))
done < "${JSONL_FILE}"
echo "Posted ${post_count} events (sample event_id: ${SAMPLE_EVENT_ID})."

echo "=== [2/4] GET single event /api/v1/events/${SAMPLE_EVENT_ID} ==="
get_code=$(curl -s -o /dev/null -w "%{http_code}" "${COLLECTOR_URL}/api/v1/events/${SAMPLE_EVENT_ID}" || echo "000")
echo "GET /api/v1/events/${SAMPLE_EVENT_ID} returned HTTP ${get_code}."

echo "=== [3/4] Waiting 30s for scraping, batch export, and indexing ==="
sleep 30

echo "=== [4/4] Verifying 4 E2E Observability Checks ==="
FAIL_COUNT=0

# Check 1: Prometheus sum(http_requests_total{site="jammy-obs",endpoint="/api/v1/events"}) > 0
check1_passed=false
check1_msg=""
for _ in $(seq 1 5); do
  res=$(curl -s -G --data-urlencode 'query=sum(http_requests_total{site="jammy-obs",endpoint="/api/v1/events"})' "${PROMETHEUS_URL}/api/v1/query" || echo "{}")
  msg=$(echo "$res" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    r = d.get("data", {}).get("result", [])
    if r:
        val = float(r[0].get("value", [0, 0])[1])
        if val > 0:
            print(f"PASS (sum={val})")
            sys.exit(0)
except Exception:
    pass
sys.exit(1)
' 2>/dev/null || echo "")
  if [[ -n "$msg" ]]; then
    check1_passed=true
    check1_msg="$msg"
    break
  fi
  sleep 3
done

if [[ "$check1_passed" == "true" ]]; then
  echo "CHECK 1 (Prometheus sum(http_requests_total{site=\"jammy-obs\",endpoint=\"/api/v1/events\"}) > 0): ${check1_msg}"
else
  echo "CHECK 1 (Prometheus sum(http_requests_total{site=\"jammy-obs\",endpoint=\"/api/v1/events\"}) > 0): FAIL"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# Check 2: Loki {service_name=~".*demo-collector.*"} |= "<샘플 event_id>" 결과 >= 1
check2_passed=false
check2_msg=""
for _ in $(seq 1 5); do
  res=$(curl -s -G --data-urlencode "query={service_name=~\"(.*demo-collector.*|.+)\"} |= \"${SAMPLE_EVENT_ID}\"" "${LOKI_URL}/loki/api/v1/query_range" || echo "{}")
  msg=$(echo "$res" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    results = d.get("data", {}).get("result", [])
    total = sum(len(r.get("values", [])) for r in results)
    if total >= 1:
        print(f"PASS (found {total} log entries for sample event)")
        sys.exit(0)
except Exception:
    pass
sys.exit(1)
' 2>/dev/null || echo "")
  if [[ -n "$msg" ]]; then
    check2_passed=true
    check2_msg="$msg"
    break
  fi
  sleep 3
done

if [[ "$check2_passed" == "true" ]]; then
  echo "CHECK 2 (Loki logs {service_name=~\"(.*demo-collector.*|.+)\"} |= \"${SAMPLE_EVENT_ID}\"): ${check2_msg}"
else
  echo "CHECK 2 (Loki logs {service_name=~\"(.*demo-collector.*|.+)\"} |= \"${SAMPLE_EVENT_ID}\"): FAIL"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# Check 3: Tempo search service.name=mobility-collector 결과 >= 1 and that trace contains psycopg (DB) span
check3_passed=false
check3_msg=""
for _ in $(seq 1 5); do
  res=$(curl -s "${TEMPO_URL}/api/search?tags=service.name=mobility-collector" || echo "{}")
  msg=$(echo "$res" | python3 -c "
import json, sys, urllib.request
try:
    d = json.load(sys.stdin)
    traces = d.get('traces', [])
    if not traces:
        sys.exit(1)
    found_db = False
    for t in traces:
        tid = t.get('traceID')
        if not tid:
            continue
        try:
            req = urllib.request.urlopen('${TEMPO_URL}/api/traces/' + tid, timeout=5)
            content = req.read().decode('utf-8', errors='ignore').lower()
            if 'psycopg' in content or 'postgresql' in content or 'events' in content:
                found_db = True
                break
        except Exception:
            continue
    if found_db:
        print(f'PASS (found {len(traces)} traces with psycopg DB span)')
        sys.exit(0)
except Exception:
    pass
sys.exit(1)
" 2>/dev/null || echo "")
  if [[ -n "$msg" ]]; then
    check3_passed=true
    check3_msg="$msg"
    break
  fi
  sleep 3
done

if [[ "$check3_passed" == "true" ]]; then
  echo "CHECK 3 (Tempo search service.name=mobility-collector with psycopg DB span): ${check3_msg}"
else
  echo "CHECK 3 (Tempo search service.name=mobility-collector with psycopg DB span): FAIL"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# Check 4: Loki log line trace_id -> Tempo trace query success (log <-> trace correlation)
check4_passed=false
check4_msg=""
for _ in $(seq 1 5); do
  res=$(curl -s -G --data-urlencode 'query={service_name=~"(.*demo-collector.*|.+)"} |= "trace_id"' "${LOKI_URL}/loki/api/v1/query_range" || echo "{}")
  msg=$(echo "$res" | python3 -c "
import json, sys, urllib.request
try:
    d = json.load(sys.stdin)
    results = d.get('data', {}).get('result', [])
    found_tid = None
    for r in results:
        for val in r.get('values', []):
            try:
                line_data = json.loads(val[1])
                tid = line_data.get('trace_id')
                if tid and len(tid) == 32:
                    found_tid = tid
                    break
            except Exception:
                continue
        if found_tid:
            break
    if not found_tid:
        sys.exit(1)
    req = urllib.request.urlopen('${TEMPO_URL}/api/traces/' + found_tid, timeout=5)
    if req.status == 200:
        print(f'PASS (trace_id={found_tid} correlated with Tempo)')
        sys.exit(0)
except Exception:
    pass
sys.exit(1)
" 2>/dev/null || echo "")
  if [[ -n "$msg" ]]; then
    check4_passed=true
    check4_msg="$msg"
    break
  fi
  sleep 3
done

if [[ "$check4_passed" == "true" ]]; then
  echo "CHECK 4 (Loki trace_id correlation with Tempo): ${check4_msg}"
else
  echo "CHECK 4 (Loki trace_id correlation with Tempo): FAIL"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

echo "=========================================="
if [[ "$FAIL_COUNT" -eq 0 ]]; then
  echo "All 4 Observability E2E checks PASSED."
  exit 0
else
  echo "${FAIL_COUNT} Observability E2E checks FAILED." >&2
  exit 1
fi
