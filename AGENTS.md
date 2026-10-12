# AGENTS.md

## Purpose

This repository is a Monaco configuration bundle that deploys ingestion, alerting, and dashboards for external synthetic tests on Dynatrace Grail.

Agents working in this repository should optimize for:
- correctness of Monaco configuration (YAML, JSON, DQL)
- documentation that is accurate for users deploying to their own Dynatrace tenants
- sample runner code that works against the documented event schema

## What this repository is

A fork-and-deploy bundle. Users clone or fork it, set environment variables, and run `make deploy`. There is no build step, no compiled artifact, and no release train. Configuration files are the product.

## Repository structure

```
monaco/
  buckets/          — Grail bucket definition
  openpipeline/     — ingest pipeline (routing, metric extraction, topology)
  custom-alerts/    — Davis anomaly detectors
  dashboards/       — Overview and Usage dashboards (DQL tiles)
manifest.yaml       — Monaco project manifest
delete.yaml         — Monaco delete manifest
Makefile            — deploy / validate / delete targets
samples/            — example runner code (Playwright wrapper, k6 template, curl)
docs/               — get-started.md, reference.md
```

## Key conventions

- Monaco project name is `dynatrace-external-tests`. It appears in `manifest.yaml`, `delete.yaml`, and inside dashboard DQL tiles that filter on bucket name.
- The Grail bucket is named `dynatrace-external-tests_events` (Monaco prepends the project name automatically from the `events` configId).
- Dashboard variables use `defaultValue` for the "show all" sentinel (`"* : All tests"` for testId, `"*"` for location). Tile DQL uses `arrayFirst(array($var)) == "sentinel"` as an escape hatch — do not replace this pattern with `isNull($var)`, which fails for multi-value variables.
- The `dt.source_entity` field in OpenPipeline topology rules must be a classic entity reference. Do not remove it or replace it with a Grail entity field.

## What to avoid

- Do not add simulation scripts or internal tooling. The `simulate` targets and scripts are intentionally excluded from this repo.
- Do not reference `docs/architecture.md` or `docs/IMPLEMENTATION.md` — those files do not exist in this repo (they were internal-only and were not published).
- Do not reintroduce the `workflow drift-detection` configuration. It was removed deliberately because the platform's `timeseries` command does not return series when all data falls outside the query window, making missing-data alerting via workflows unreliable.
- Do not set `alertOnMissingData: true` on the custom alert detectors for the same reason.
- Do not delete the Grail bucket in `delete.yaml` — the bucket is intentionally absent to preserve ingested data when a user runs `make delete`.

## Pull request guidance

- Run `make validate` before proposing changes to Monaco configuration.
- Test changes against a real Dynatrace tenant with a real event — `make validate` passes configuration syntax but cannot verify that a pipeline rule, detector, or dashboard tile produces the intended result.
- If you change `docs/get-started.md` or `docs/reference.md`, verify that field names, file paths, and parameter names still match the actual configuration.
