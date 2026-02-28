# AGENTS.md instructions for /Users/vladi/dev/bigquery-overture-skill

## Skills
A skill is a set of local instructions to follow that is stored in a `SKILL.md` file.

### Available skills
- bigquery-overture-skill: Build and optionally execute cost-safe Overture Maps SQL via `bq` CLI, with dry-run budget guardrails and visualization handoff. Use when users need Overture Maps queries in BigQuery and want either verified SQL or executed results. (file: /Users/vladi/dev/bigquery-overture-skill/SKILL.md)

### How to use skills
- Trigger rules: If the user names the skill (`$bigquery-overture-skill`) or the request clearly matches its description, use it for that turn.
- Loading: Open `/Users/vladi/dev/bigquery-overture-skill/SKILL.md` and follow it.
- Scope: Do not carry this skill across turns unless re-mentioned or clearly required by the new request.
