# bigquery-overture-skill

Build and optionally execute cost-safe Overture Maps SQL in BigQuery using `bq`, with mandatory dry-run budget checks and visualization handoff.

## What this skill does

- Supports `sql_only` (default) and `execute` modes
- Enforces dry run before execution
- Enforces `maximum_bytes_billed`
- Blocks over-budget execution unless explicitly overridden
- Returns a consistent JSON output contract for downstream use
- Works in Codex CLI, Claude CLI, and Codex App shell contexts

## Prerequisites

This skill does **not** install software automatically.

Install prerequisites manually:

### 1) Google Cloud SDK + bq CLI

macOS (Homebrew cask):

```bash
brew install --cask google-cloud-sdk
```

Initialize and authenticate:

```bash
gcloud init
gcloud auth login
gcloud auth application-default login
gcloud config set project <PROJECT_ID>
```

Verify:

```bash
bq version
bq ls
```

### 2) Access to BigQuery datasets (including Overture tables)

Ensure your identity/service account has required IAM roles to run queries on target datasets.

## Optional environment variables

You can define these in shell env or in a local `.env` file:

- `BQ_PROJECT_ID` (fallback: active gcloud project)
- `BQ_LOCATION` (fallback: BigQuery default)
- `BQ_MAX_BYTES_BILLED` (fallback: `10737418240` bytes)
- `GOOGLE_APPLICATION_CREDENTIALS`
- `BIGQUERY_CREDENTIALS_BASE64`

If `.env` is present, the script auto-loads it.

### Cost of default `BQ_MAX_BYTES_BILLED`

`10737418240` bytes is `10 GiB` (about `0.009765625 TiB`).

At BigQuery on-demand analysis pricing (`$6.25 / TiB`), that cap is about:

- `$0.061` max per query (about `6.1 cents`)

Formula:

```text
10 GiB / 1024 GiB per TiB * $6.25 = $0.06103515625
```

Note: BigQuery includes monthly free query usage (first 1 TiB), so effective billed cost can be lower or zero depending on project usage.

## Use with Codex CLI (step by step)

Default Codex home is `~/.codex` when `CODEX_HOME` is not set.

### No-install local use (open this folder and run)

This repo includes `AGENTS.md` + `SKILL.md`, so Codex can use the skill directly when started in this directory.

1. Open terminal in `/Users/vladi/dev/bigquery-overture-skill`.
2. Start Codex CLI in this folder.
3. Ask naturally, or explicitly invoke `$bigquery-overture-skill`.

No copy/symlink install is required for this local workflow.

1. Install this skill into your Codex skills directory:

```bash
CODEX_SKILLS_DIR="${CODEX_HOME:-$HOME/.codex}/skills"
mkdir -p "$CODEX_SKILLS_DIR/bigquery-overture-skill"
cp -R /Users/vladi/dev/bigquery-overture-skill/. "$CODEX_SKILLS_DIR/bigquery-overture-skill/"
```

Or use a symlink (useful during active development):

```bash
CODEX_SKILLS_DIR="${CODEX_HOME:-$HOME/.codex}/skills"
mkdir -p "$CODEX_SKILLS_DIR"
ln -sfn /Users/vladi/dev/bigquery-overture-skill "$CODEX_SKILLS_DIR/bigquery-overture-skill"
```

2. Confirm required skill files exist:

```bash
CODEX_SKILLS_DIR="${CODEX_HOME:-$HOME/.codex}/skills"
ls -la "$CODEX_SKILLS_DIR/bigquery-overture-skill"
```

You should see at least:
- `SKILL.md`
- `agents/openai.yaml`
- `scripts/run_cost_checked_query.sh`

3. Open your project/work directory where you want to run queries.

4. (Optional) Create a local `.env` with BigQuery settings:

```bash
cat > .env <<'EOF'
BQ_PROJECT_ID=your-project-id
BQ_LOCATION=US
BQ_MAX_BYTES_BILLED=10737418240
EOF
```

5. Start Codex CLI in that directory.

6. Invoke the skill explicitly in your prompt using `$bigquery-overture-skill`.

Example prompts:
- `Use $bigquery-overture-skill to prepare a Berlin rail query with strict bbox prefilter and verify cost first.`
- `Use $bigquery-overture-skill to get a COUNT(*) preview for DE-BE buildings and return the result if it is within budget.`

## Output contract

The skill returns JSON with:

- `mode`
- `status` (`dry_run_only | executed | blocked_over_budget`)
- `project_id`
- `location`
- `estimated_bytes`
- `max_bytes_billed`
- `query_sql`
- `result_preview` (only when executed)
- `visualization_handoff` (`dekart`, `bigquery_studio`)
- `next_steps`

## Notes for Codex App

Codex App runs in a shell context and the script reads `.env` from the current working directory, so env resolution is consistent with CLI usage.
