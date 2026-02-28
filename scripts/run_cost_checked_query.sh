#!/usr/bin/env bash
set -euo pipefail

MODE="sql_only"
QUERY_SQL=""
QUERY_FILE=""
ALLOW_OVER_BUDGET="false"
RESULT_MAX_ROWS="20"
PROJECT_ID_OVERRIDE=""
LOCATION_OVERRIDE=""
MAX_BYTES_OVERRIDE=""

print_usage() {
  cat <<'USAGE'
Usage:
  run_cost_checked_query.sh --query "<sql>" [options]
  run_cost_checked_query.sh --query-file /path/query.sql [options]

Options:
  --mode sql_only|execute       Default: sql_only
  --query <sql>                 SQL text
  --query-file <path>           File containing SQL
  --project-id <id>             Override project
  --location <loc>              Override location
  --max-bytes <int>             Override maximum_bytes_billed
  --allow-over-budget           Allow execute when dry-run estimate exceeds budget
  --result-max-rows <int>       Preview rows when executed (default: 20)
  -h, --help                    Show this help
USAGE
}

fail_json() {
  local message="$1"
  local next_steps_json="$2"
  python3 - <<'PY' "$MODE" "$PROJECT_ID" "$LOCATION" "$ESTIMATED_BYTES" "$MAX_BYTES" "$QUERY_SQL" "$message" "$next_steps_json"
import json
import sys
mode, project_id, location, estimated, max_bytes, query_sql, message, next_steps_json = sys.argv[1:9]
out = {
  "mode": mode,
  "status": "dry_run_only",
  "project_id": project_id or None,
  "location": location or None,
  "estimated_bytes": int(estimated) if estimated and estimated.isdigit() else 0,
  "max_bytes_billed": int(max_bytes) if max_bytes and max_bytes.isdigit() else 0,
  "query_sql": query_sql,
  "result_preview": None,
  "visualization_handoff": {
    "dekart": "Open Dekart, connect to the same BigQuery project, paste query_sql, and map geometry columns.",
    "bigquery_studio": f"Open https://console.cloud.google.com/bigquery?project={project_id} and paste query_sql in the SQL workspace."
  },
  "next_steps": json.loads(next_steps_json),
  "error": message
}
print(json.dumps(out, ensure_ascii=True, indent=2))
PY
  exit 1
}

while (($#)); do
  case "$1" in
    --mode)
      MODE="${2:-}"
      shift 2
      ;;
    --query)
      QUERY_SQL="${2:-}"
      shift 2
      ;;
    --query-file)
      QUERY_FILE="${2:-}"
      shift 2
      ;;
    --project-id)
      PROJECT_ID_OVERRIDE="${2:-}"
      shift 2
      ;;
    --location)
      LOCATION_OVERRIDE="${2:-}"
      shift 2
      ;;
    --max-bytes)
      MAX_BYTES_OVERRIDE="${2:-}"
      shift 2
      ;;
    --allow-over-budget)
      ALLOW_OVER_BUDGET="true"
      shift
      ;;
    --result-max-rows)
      RESULT_MAX_ROWS="${2:-}"
      shift 2
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      print_usage >&2
      exit 2
      ;;
  esac
done

if [[ "$MODE" != "sql_only" && "$MODE" != "execute" ]]; then
  echo "--mode must be sql_only or execute" >&2
  exit 2
fi

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

if [[ -n "$QUERY_FILE" ]]; then
  if [[ ! -f "$QUERY_FILE" ]]; then
    echo "--query-file not found: $QUERY_FILE" >&2
    exit 2
  fi
  QUERY_SQL="$(cat "$QUERY_FILE")"
fi

if [[ -z "$QUERY_SQL" ]]; then
  echo "Provide SQL with --query or --query-file" >&2
  exit 2
fi

PROJECT_ID="${PROJECT_ID_OVERRIDE:-${BQ_PROJECT_ID:-}}"
LOCATION="${LOCATION_OVERRIDE:-${BQ_LOCATION:-}}"
MAX_BYTES="${MAX_BYTES_OVERRIDE:-${BQ_MAX_BYTES_BILLED:-10737418240}}"
ESTIMATED_BYTES="0"

if [[ -z "$PROJECT_ID" ]] && command -v gcloud >/dev/null 2>&1; then
  PROJECT_ID="$(gcloud config get-value project 2>/dev/null | tr -d '\r')"
fi

if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "(unset)" ]]; then
  fail_json "Project could not be resolved." '["Set BQ_PROJECT_ID or run: gcloud config set project <PROJECT_ID>"]'
fi

if ! command -v bq >/dev/null 2>&1; then
  fail_json "bq CLI is not available." '["Install Google Cloud SDK and bq CLI, then authenticate before rerunning.","macOS example: brew install --cask google-cloud-sdk"]'
fi

if [[ -n "${BIGQUERY_CREDENTIALS_BASE64:-}" && -z "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]]; then
  mkdir -p .tmp
  printf '%s' "$BIGQUERY_CREDENTIALS_BASE64" | base64 --decode > .tmp/bq-creds.json
  export GOOGLE_APPLICATION_CREDENTIALS="$PWD/.tmp/bq-creds.json"
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
DRY_RUN_OUT="$TMP_DIR/dry_run.json"
DRY_RUN_ERR="$TMP_DIR/dry_run.err"

BQ_DRY_ARGS=(
  query
  --use_legacy_sql=false
  --dry_run
  --format=json
  --project_id="$PROJECT_ID"
  --maximum_bytes_billed="$MAX_BYTES"
)
if [[ -n "$LOCATION" ]]; then
  BQ_DRY_ARGS+=(--location="$LOCATION")
fi
BQ_DRY_ARGS+=("$QUERY_SQL")

if ! bq "${BQ_DRY_ARGS[@]}" >"$DRY_RUN_OUT" 2>"$DRY_RUN_ERR"; then
  DRY_ERR_MSG="$(tr '\n' ' ' < "$DRY_RUN_ERR" | sed 's/"/\\"/g')"
  fail_json "Dry run failed: $DRY_ERR_MSG" '["Validate SQL syntax and dataset/table names.","Verify auth with: gcloud auth application-default login"]'
fi

ESTIMATED_BYTES="$(python3 - <<'PY' "$DRY_RUN_OUT"
import json
import sys
from pathlib import Path
p = Path(sys.argv[1])
obj = json.loads(p.read_text())
val = obj.get("statistics", {}).get("query", {}).get("totalBytesProcessed", "0")
print(val)
PY
)"

STATUS="dry_run_only"
RESULT_PREVIEW_JSON="null"
NEXT_STEPS='["Open Dekart or BigQuery Studio with query_sql.","If needed, tighten bbox/date filters or reduce selected columns."]'

if [[ "$MODE" == "execute" ]]; then
  if [[ "$ALLOW_OVER_BUDGET" != "true" && "$ESTIMATED_BYTES" -gt "$MAX_BYTES" ]]; then
    STATUS="blocked_over_budget"
    NEXT_STEPS='["Query blocked because dry-run estimate exceeds max_bytes_billed.","Try tighter bbox/date filters, fewer columns, or pre-aggregation before geometry joins."]'
  else
    EXEC_OUT="$TMP_DIR/exec_rows.json"
    EXEC_ERR="$TMP_DIR/exec.err"

    BQ_EXEC_ARGS=(
      query
      --use_legacy_sql=false
      --format=json
      --project_id="$PROJECT_ID"
      --maximum_bytes_billed="$MAX_BYTES"
      --max_rows="$RESULT_MAX_ROWS"
    )
    if [[ -n "$LOCATION" ]]; then
      BQ_EXEC_ARGS+=(--location="$LOCATION")
    fi
    BQ_EXEC_ARGS+=("$QUERY_SQL")

    if ! bq "${BQ_EXEC_ARGS[@]}" >"$EXEC_OUT" 2>"$EXEC_ERR"; then
      EXEC_ERR_MSG="$(tr '\n' ' ' < "$EXEC_ERR" | sed 's/"/\\"/g')"
      fail_json "Execution failed: $EXEC_ERR_MSG" '["Check SQL and permissions.","Retry after narrowing filters or lowering output cardinality."]'
    fi

    RESULT_PREVIEW_JSON="$(cat "$EXEC_OUT")"
    STATUS="executed"
    NEXT_STEPS='["Review result_preview and iterate query predicates if needed.","Open the same SQL in Dekart or BigQuery Studio for visualization."]'
  fi
fi

python3 - <<'PY' "$MODE" "$STATUS" "$PROJECT_ID" "$LOCATION" "$ESTIMATED_BYTES" "$MAX_BYTES" "$QUERY_SQL" "$RESULT_PREVIEW_JSON" "$NEXT_STEPS"
import json
import sys
mode, status, project_id, location, estimated, max_bytes, query_sql, preview_json, next_steps_json = sys.argv[1:10]
preview = None if preview_json == "null" else json.loads(preview_json)
out = {
  "mode": mode,
  "status": status,
  "project_id": project_id,
  "location": location or None,
  "estimated_bytes": int(estimated),
  "max_bytes_billed": int(max_bytes),
  "query_sql": query_sql,
  "result_preview": preview,
  "visualization_handoff": {
    "dekart": "Open Dekart, connect to the same BigQuery project, paste query_sql, and map geometry columns.",
    "bigquery_studio": f"Open https://console.cloud.google.com/bigquery?project={project_id} and paste query_sql in the SQL workspace."
  },
  "next_steps": json.loads(next_steps_json)
}
print(json.dumps(out, ensure_ascii=True, indent=2))
PY
