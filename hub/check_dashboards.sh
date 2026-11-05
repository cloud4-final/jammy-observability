#!/usr/bin/env bash
set -euo pipefail

GRAFANA_URL="${GRAFANA_URL:-http://127.0.0.1:3000}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://127.0.0.1:9090}"
LOKI_URL="${LOKI_URL:-http://127.0.0.1:3100}"
SECRETS_DIR="${SECRETS_DIR:-/opt/jammy-obs/secrets}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --grafana-url)
      GRAFANA_URL="$2"
      shift 2
      ;;
    --prometheus-url)
      PROMETHEUS_URL="$2"
      shift 2
      ;;
    --loki-url)
      LOKI_URL="$2"
      shift 2
      ;;
    --secrets-dir)
      SECRETS_DIR="$2"
      shift 2
      ;;
    --password)
      ADMIN_PASSWORD="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [--grafana-url <url>] [--prometheus-url <url>] [--loki-url <url>] [--secrets-dir <dir>] [--password <pass>]"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "${ADMIN_PASSWORD}" ]]; then
  PASS_FILE="${SECRETS_DIR}/grafana_admin_password"
  if [[ -f "${PASS_FILE}" ]]; then
    ADMIN_PASSWORD="$(tr -d '\r\n' < "${PASS_FILE}")"
  else
    echo "ERROR: Grafana admin password file not found: ${PASS_FILE}" >&2
    exit 1
  fi
fi

DASHBOARDS=("jammy-noc" "jammy-network" "jammy-vms" "jammy-app")

echo "=== Verifying 4 Live Dashboards via Grafana API ==="

FAIL_COUNT=0
for uid in "${DASHBOARDS[@]}"; do
  url="${GRAFANA_URL}/api/dashboards/uid/${uid}"
  resp=$(curl -s -f -u "${ADMIN_USER}:${ADMIN_PASSWORD}" "${url}" || echo "")
  if [[ -z "${resp}" ]]; then
    echo "ERROR: Failed to fetch dashboard UID: ${uid} from ${url}" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
    continue
  fi

  # shellcheck disable=SC2016
  if ! python3 -c '
import sys, json, re, urllib.request, urllib.parse

prom_url = sys.argv[1]
loki_url = sys.argv[2]
raw_json = sys.stdin.read()

try:
    payload = json.loads(raw_json)
except Exception as e:
    print(f"Error parsing dashboard json: {e}", file=sys.stderr)
    sys.exit(1)

dashboard = payload.get("dashboard", {})
title = dashboard.get("title", "Untitled")
uid = dashboard.get("uid", "")
print(f"\n--- [{title}] (UID: {uid}) ---")

has_error = False

# 1. Verify template variables
variables = dashboard.get("templating", {}).get("list", [])
var_map = {}
for v in variables:
    v_name = v.get("name", "")
    v_type = v.get("type", "")
    current = v.get("current", {})
    cur_val = current.get("value")
    all_val = v.get("allValue") or ".*"

    if cur_val in (None, ""):
        print(f"  Variable ${v_name}: ERROR (current.value is empty)")
        has_error = True
        continue

    effective_val = all_val if cur_val == "$__all" else cur_val
    var_map[f"${v_name}"] = effective_val

    if v_type == "query":
        q_raw = v.get("query", "")
        q_str = q_raw.get("query", "") if isinstance(q_raw, dict) else str(q_raw)

        if "=~\"\"" in q_str or "!~\"\"" in q_str or "=~\"\"" in str(v.get("definition", "")):
            print(f"  Variable ${v_name} ({q_str}): ERROR (contains empty regex)")
            has_error = True
            continue

        m = re.match(r"^label_values\((?:(.+),\s*)?([a-zA-Z_0-9]+)\)$", q_str.strip())
        if m:
            metric_selector, label_name = m.group(1), m.group(2)
            if metric_selector:
                for vk, vv in var_map.items():
                    metric_selector = metric_selector.replace(vk, str(vv))
                metric_selector = re.sub(r"\$[a-zA-Z_0-9]+", ".*", metric_selector)

            params = {}
            if metric_selector:
                params["match[]"] = metric_selector
            val_url = prom_url + f"/api/v1/label/{label_name}/values"
            if params:
                val_url += "?" + urllib.parse.urlencode(params)

            try:
                with urllib.request.urlopen(val_url, timeout=10) as r:
                    res = json.loads(r.read()).get("data", [])
                    cnt = len(res)
                    if cnt > 0:
                        print(f"  Variable ${v_name}: {cnt} values")
                    else:
                        print(f"  Variable ${v_name} ({q_str}): EMPTY (0 values returned)")
                        has_error = True
            except Exception as e:
                print(f"  Variable ${v_name} ({q_str}): ERROR ({e})")
                has_error = True

panels = dashboard.get("panels", [])
for p in panels:
    p_type = p.get("type")
    p_title = p.get("title") or "(no title)"
    if p_type == "row":
        continue
    if p_type == "text":
        print(f"  {p_title}: SKIPPED (text panel)")
        continue
    if p_type == "alertlist":
        print(f"  {p_title}: SKIPPED (alertlist panel)")
        continue

    targets = p.get("targets", [])
    if not targets:
        print(f"  {p_title}: EMPTY (no targets)")
        continue

    for t in targets:
        ref = t.get("refId", "A")
        raw_expr = t.get("expr", "")
        ds = t.get("datasource", {})
        ds_uid = ds.get("uid") if isinstance(ds, dict) else ds
        if not ds_uid:
            p_ds = p.get("datasource", {})
            ds_uid = p_ds.get("uid") if isinstance(p_ds, dict) else p_ds

        target_label = p_title if len(targets) == 1 else f"{p_title} ({ref})"

        if not raw_expr:
            if ds_uid == "tempo":
                print(f"  {target_label}: SKIPPED (tempo trace search)")
            else:
                print(f"  {target_label}: EMPTY (empty expression)")
            continue

        expr = raw_expr
        for vk, vv in var_map.items():
            expr = expr.replace(vk, str(vv))
        expr = expr.replace("$site", ".*").replace("$domain", ".*")
        expr = expr.replace("$__rate_interval", "2m").replace("$__interval", "2m").replace("$__range", "1h")

        if ds_uid == "loki":
            loki_expr = expr
            if loki_expr == "{site=~\".*\"}":
                loki_expr = "{site=~\".+\"}"
            q_url = loki_url + "/loki/api/v1/query_range?" + urllib.parse.urlencode({"query": loki_expr, "limit": "5"})
            try:
                with urllib.request.urlopen(q_url, timeout=10) as r:
                    res = json.loads(r.read()).get("data", {}).get("result", [])
                    cnt = len(res)
                    if cnt > 0:
                        print(f"  {target_label}: {cnt} series")
                    else:
                        print(f"  {target_label}: EMPTY")
            except Exception as e:
                print(f"  {target_label}: ERROR ({e})")
                has_error = True
        elif ds_uid == "prometheus":
            q_url = prom_url + "/api/v1/query?" + urllib.parse.urlencode({"query": expr})
            try:
                with urllib.request.urlopen(q_url, timeout=10) as r:
                    res = json.loads(r.read()).get("data", {}).get("result", [])
                    cnt = len(res)
                    if cnt > 0:
                        print(f"  {target_label}: {cnt} series")
                    else:
                        print(f"  {target_label}: EMPTY")
            except Exception as e:
                print(f"  {target_label}: ERROR ({e})")
                has_error = True
        else:
            print(f"  {target_label}: SKIPPED (datasource: {ds_uid})")

if has_error:
    sys.exit(1)
' "${PROMETHEUS_URL}" "${LOKI_URL}" <<< "${resp}"; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi

done

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
  echo -e "\n❌ Dashboard verification failed (${FAIL_COUNT} dashboards had errors)." >&2
  exit 1
fi

echo -e "\n✅ All live dashboard panels verified."
