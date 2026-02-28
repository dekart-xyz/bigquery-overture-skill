---
name: bigquery-overture-skill
description: Build and optionally execute cost-safe Overture Maps SQL through the BigQuery bq CLI, with mandatory dry-run cost checks and visualization handoff. Use when a user needs map-ready Overture Maps queries in BigQuery, wants SQL-only output or executed numeric results, and needs budget enforcement with clear over-budget fallback options.
---

# BigQuery Overture Cost Aware

Use this skill for Overture Maps work in BigQuery with strict cost controls.

## Non-Installation Rule

Never install software automatically. If dependencies are missing, report exact prerequisite commands for the user to run.

## Preferred Execution Path

Use the bundled script for deterministic behavior:

```bash
./scripts/run_cost_checked_query.sh --query-file /path/to/query.sql --mode sql_only
```

Or:

```bash
./scripts/run_cost_checked_query.sh --query "SELECT ..." --mode execute
```

Script location:
- `scripts/run_cost_checked_query.sh`

The script already handles:
- Optional `.env` loading from current working directory
- `BQ_PROJECT_ID` fallback to `gcloud config get-value project`
- `BQ_LOCATION` optional passthrough
- `BQ_MAX_BYTES_BILLED` safe default `10737418240` (10 GiB)
- Optional auth env support: `GOOGLE_APPLICATION_CREDENTIALS`, `BIGQUERY_CREDENTIALS_BASE64`
- Mandatory dry run and bytes budget gate before execution

## Inputs

Collect or infer:
- `mode`: infer from user intent (`sql_only` for query drafting/verification, `execute` when user asks for actual numbers/results)
- User intent: dataset/theme, filters, output columns, aggregation, map vs numeric output
- Optional bounds: bbox, date/time, row limit
- Optional explicit over-budget override

## Guardrails

Apply all guardrails every time:
1. Run dry run before execution.
2. Enforce `maximum_bytes_billed`.
3. Prefer bounded SQL by default (bbox/date/limit, minimal selected columns).
4. If estimated bytes exceed budget and no explicit override: do not execute.
5. If over budget: provide lower-cost SQL variants.

## Query Construction Rules

1. Select only required columns; avoid `SELECT *`.
2. Prefer filtered Overture tables and partition-friendly predicates.
3. Add default limits when user omitted bounds:
- Spatial bounding constraints for map requests
- Row cap (`LIMIT`) for previews
4. Separate heavy geometry retrieval from numeric aggregation when practical.

## Schema Discovery Patterns

List Overture tables:

```sql
SELECT table_name
FROM `bigquery-public-data.overture_maps.INFORMATION_SCHEMA.TABLES`
ORDER BY table_name;
```

List columns for one table:

```sql
SELECT
  column_name,
  data_type,
  is_nullable,
  ordinal_position
FROM `bigquery-public-data.overture_maps.INFORMATION_SCHEMA.COLUMNS`
WHERE table_name = 'division_area'
ORDER BY ordinal_position;
```

## Querying Overture Safely (Small/Fast Only)

Rules:
- Always start with selective `WHERE` filters.
- Always include a hard-coded bbox prefilter on `bbox.xmin/xmax/ymin/ymax` for large feature tables (for example, `segment`, `building`, `place`).
- Do not rely on dynamic boundary filters alone (for example, `ST_INTERSECTS(s.geometry, city.geometry)` from a CTE/subquery) as the primary filter, because this can trigger broad scans.
- Treat dynamic boundary geometry as a secondary exact clip only, after the hard-coded bbox gate.
- Add `LIMIT` for exploration.
- Prefer aggregate previews (`COUNT(*)`) before geometry-heavy pulls.
- Avoid full table scans and large result sets.

Example (optimized rail query pattern):

```sql
WITH city AS (
  SELECT geometry
  FROM `bigquery-public-data.overture_maps.division_area`
  WHERE country = 'DE'
    AND region = 'DE-BE'
    AND subtype = 'region'
    AND class = 'land'
  LIMIT 1
)
SELECT
  s.id,
  s.geometry
FROM `bigquery-public-data.overture_maps.segment` s
CROSS JOIN city c
WHERE s.subtype = 'rail'
  -- hardcoded city bbox (Berlin in this example)
  AND s.bbox.xmax >= 13.08834457397461
  AND s.bbox.xmin <= 13.761162757873535
  AND s.bbox.ymax >= 52.33823776245117
  AND s.bbox.ymin <= 52.67551040649414
  -- exact clip after bbox gate
  AND ST_INTERSECTS(s.geometry, c.geometry)
LIMIT 1000;
```

## Recommended Agent Workflow

1. Discover table and column metadata via `INFORMATION_SCHEMA`.
2. Resolve the target area's bbox once and copy the numeric constants into the final query (hardcoded).
3. Draft a minimal query with bbox prefilter first, then exact geometry clip (`ST_INTERSECTS`) second.
4. Validate output shape and types with `LIMIT` or `COUNT(*)`.
5. Iterate in small steps; do not run broad/full extraction queries unless explicitly requested.

## Mode Behavior

Decide mode automatically unless user explicitly requests one.

### `sql_only` (default)
- Build optimized SQL
- Run mandatory dry run
- Return SQL + estimated bytes + budget pass/fail + visualization handoff

### `execute`
- Build optimized SQL
- Run mandatory dry run
- Execute only if user asked for results and estimate is within budget (or explicit user override)
- Return rows/aggregates preview + SQL + visualization handoff

## Failure Handling

If `bq` unavailable or auth fails:
- Return exact fix commands only (no auto-install/no auto-auth side effects).

If over budget:
- Keep `status=blocked_over_budget`
- Do not execute query
- Return at least one cheaper SQL variant

If query invalid:
- Return corrected SQL draft and rerun dry-run logic

## Output Contract

Always return:
- `mode`
- `status` (`dry_run_only | executed | blocked_over_budget`)
- `project_id`
- `location`
- `estimated_bytes`
- `max_bytes_billed`
- `query_sql`
- `result_preview` (if executed)
- `visualization_handoff` (`dekart`, `bigquery_studio`)
- `next_steps`

## Visualization Handoff

Always include both handoffs:
- `dekart`: open Dekart, connect to same project, paste `query_sql`, map geometry fields.
- `bigquery_studio`: open `https://console.cloud.google.com/bigquery?project=<PROJECT_ID>` and paste `query_sql` in SQL workspace.

## Response Quality Rules

1. Be explicit about budget pass/fail.
2. Show the final SQL used for dry run.
3. Keep previews concise.
4. If blocked, include cheaper alternatives.
