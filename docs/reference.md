# External tests reference

- Latest Dynatrace
- Concept, Task, Reference

External tests are synthetic checks you run with your own tooling and send the results to Dynatrace: Playwright and Selenium suites, mobile or desktop app tests, protocol checks, load tests, or a third-party synthetic product. The results arrive as generic events. OpenPipeline then turns those events into metrics, Smartscape topology, Davis problems, and dashboards. Externally executed tests are treated like any other data source in your Dynatrace environment, alongside OneAgent, OpenTelemetry, and native Synthetic Monitoring data.

This page is the complete reference: the data model, every pipeline processor, alerting, DQL, cost, and deployment. If you want a first test reporting in under an hour, start with [Get started with external tests](get-started.md).

## Key terms

External test
: A test executed outside Dynatrace — by your own runner, a scheduler, a CI pipeline, or a third-party synthetic product — whose results you ingest into Dynatrace.

Run
: One execution of an external test (one schedule tick, one CI trigger, or one manual invocation). Represented by an event of type `external_test_run`.

Step
: One action inside a run, such as a page navigation, an API call, a click, or an assertion. Represented by an event of type `external_test_step`.

Test ID (`test.id`)
: The stable identifier of the test *definition*. It persists across executions and becomes the identity of the Smartscape node. Contrast with `test.run.id`, which is unique per execution.

EXT_TEST node
: The Smartscape topology node that OpenPipeline extracts for each unique `test.id`. It gives Davis problems a named entity to attach to and can be linked to the frontend the test exercises.

Starter pack
: A set of ready-made OpenPipeline pipelines, Davis anomaly detectors, and dashboards, delivered as Monaco configuration, that you deploy and then adapt to your own tests.

---

## How the model works

Your runner posts JSON to an OpenPipeline custom ingest source. OpenPipeline routes the records, masks credentials, extracts metrics, registers each test in Smartscape topology, and stores the events in a Grail bucket. Everything downstream (Davis problems and dashboards) is built on those metrics and events.

Four properties follow from using generic events rather than a dedicated API, and they're what the rest of this page builds on:

| Property | What it means in practice |
| --- | --- |
| **Schema-on-read** | Send any field your framework produces. The starter pack defines a small required field set for routing, metric extraction, topology, and correlation, but additional fields are stored without pipeline changes. They increase event size and may affect ingest and retention usage. |
| **Run-and-step granularity** | Send one event per run and, when useful, one event per step. Each event can retain the diagnostic context supplied by the runner, including error codes, stack traces, screenshot and artifact URLs, and CI metadata. |
| **Native topology** | Each test becomes a Smartscape `EXT_TEST` node. Send `dt.smartscape.frontend` to create an `EXT_TEST → FRONTEND` edge; use `dt.entity.application` separately to associate Davis problems with a classic application entity. |
| **Full DQL** | Query raw events for detailed investigations and use extracted metrics for aggregated long-term signals. |

Ingest and retention usage depend on event volume, event size, retention, and the metric data points extracted by OpenPipeline. At typical synthetic-monitoring volumes this can remain modest, but send diagnostic context deliberately—especially for high-frequency tests and step events.

The starter pack is configuration, not a product feature. You own it, you deploy it, and you adapt it. That also means you can change every threshold, metric key, and dimension.

### Use cases

- **Consolidate a fragmented test estate.** Playwright suites in GitHub Actions, k6 load tests in a nightly job, and a vendor mobile test farm all report into one Dynatrace environment with one query language.
- **Close the CI/CD feedback loop.** Tag every run with `ci.commit.sha` and `ci.pipeline.id`, then answer "which commit broke the checkout flow?" in DQL.
- **Alert on business-relevant flows you can't instrument from inside.** A checkout that runs from a partner network, or a test that authenticates against an external identity provider.
- **Give Davis a named entity.** Problems read "External test *Checkout Flow — Production* is unavailable in eu-west-1" rather than pointing at the environment.

---

## Architecture and data flow

```
Runner (Playwright / Selenium / k6 / curl / CI job)
   │  POST /platform/ingest/custom/events/external.tests
   │  Authorization: Api-Token <platform token>
   ▼
Custom ingest source  "External Test Results"   (sourceType: http, pathSegment: external.tests)
   ▼
OpenPipeline dynamic routing        builtin:openpipeline.events.routing
   ├─ event.type == "external_test_run"   ─────►  pipeline-external-test-runs
   └─ event.type == "external_test_step"  ─────►  pipeline-external-test-steps
   ▼
Pipeline processing                 builtin:openpipeline.events.pipelines
   ├─ processing                URL masking, status normalization, parent-node stitching
   ├─ metricExtraction          external.test.availability, .duration, .failures.by_code,
   │                            .usage.events_ingested, .step.duration
   ├─ smartscapeNodeExtraction  EXT_TEST node  ──monitors──►  FRONTEND
   └─ storage                   bucketAssignment → dedicated events bucket
   ▼
Grail
   ├─ events table, dedicated bucket        →  fetch events
   ├─ metrics  external.test.*              →  timeseries
   └─ Smartscape topology                   →  smartscapeNodes / smartscapeEdges
   ▼
Consumption
   ├─ Davis anomaly detectors  → Davis problems → notification profiles
   └─ Dashboards (Overview, Usage)
```

Two properties of this flow are worth understanding before you configure anything:

- **Events are the source of truth; metrics are the aggregated projection.** Raw events carry diagnostic detail and are subject to bucket retention. Extracted metrics provide longer-term signals and are what the alerts evaluate. Design your dimensions accordingly: a dimension that is not extracted cannot be used to split or identify an alert.
- **Metric extraction adds latency.** A data point must be published before a Davis anomaly detector's scheduled query can see it. Expect tens of seconds of additional delay compared to reacting to the raw event directly.

---

## Prerequisites

| Requirement | Detail |
| --- | --- |
| Environment | A Dynatrace SaaS environment on Grail with OpenPipeline available for the **Events** configuration scope |
| Ingest token | A platform token with the `openpipeline:events.custom:ingest` scope |
| Configuration permissions | Permission to create OpenPipeline ingest sources, pipelines, and routing; see [Token scopes](#token-scopes) |
| Grail bucket permissions | `storage:bucket-definitions:read` and `storage:bucket-definitions:write` if you create a dedicated bucket |
| Runner | Any test tool that can issue an HTTP POST at the end of a run |

### Token scopes

Use separate tokens for ingestion and for configuration. The runner token must not be able to read data.

**Runner (ingest) token.** Exactly one scope:

```
openpipeline:events.custom:ingest
```

> **Warning**
> `events.ingest` and `openpipeline.events.custom` are not valid scope names. A token that uses either of them is rejected.

**Configuration (deployment) token:**

```
openpipeline:configurations:read
openpipeline:configurations:write
settings:schemas:read
settings:objects:read
settings:objects:write
settings:objects:admin          # OpenPipeline routing is global configuration
storage:bucket-definitions:read
storage:bucket-definitions:write
document:documents:read
document:documents:write
document:documents:delete
document:trash.documents:delete
app-engine:apps:run
```

> **Warning**
> The deploying user must also belong to a group that has the **Data Processing and Storage** policy assigned. Without it, OpenPipeline configuration fails with `403` even when all token scopes are correct.

**Davis anomaly detector actor.** Create a dedicated service user for the detectors:

```
davis:analyzers:execute
storage:events:read
storage:metrics:read
iam:service-users:use
```

To narrow write access to anomaly detectors only:

```
ALLOW settings:schemas:read, settings:objects:write
WHERE settings:schemaId = "builtin:davis.anomaly-detectors";
```

**Query token** (dashboards, ad-hoc DQL): `storage:events:read`, `storage:metrics:read`, bound to data-access policies through `dt.security_context`.

---

## Get started

### Step 1 Create the custom ingest source

Create a custom ingest source for the **Events** configuration scope. In OpenPipeline settings, or as configuration:

```json
{
  "displayName": "External Test Results",
  "enabled": true,
  "sourceType": "http",
  "pathSegment": "external.tests"
}
```

The `pathSegment` becomes the last part of the ingest URL:

```
https://<environment-id>.live.dynatrace.com/platform/ingest/custom/events/external.tests
```

> **Warning**
> The ingest URL uses the **classic environment domain** (`<environment-id>.live.dynatrace.com`), not the platform domain (`<tenant>.apps.dynatrace.com`). Both address the same environment, but only the classic environment domain accepts ingest.

Use a dedicated custom ingest source rather than the built-in generic events endpoint. It's an isolated entry point that you can route statically, pre-process independently, and revoke without affecting other event producers.

### Step 2 Send your first event

Post a single JSON object, or a JSON array of objects, with `Content-Type: application/json`. A successful ingest returns **HTTP 202**.

```bash
DT_ENDPOINT="https://<environment-id>.live.dynatrace.com/platform/ingest/custom/events/external.tests"
DT_TOKEN="dt0s01.XXXXXXXX.XXXXXXXX"
RUN_ID="$(uuidgen)"

curl -sS -X POST "$DT_ENDPOINT" \
  -H "Authorization: Api-Token $DT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '[
    {
      "event.kind": "EXTERNAL_TEST_EVENT",
      "event.type": "external_test_run",
      "test.id": "my-first-test",
      "test.name": "My First Test",
      "test.type": "browser",
      "test.run.id": "'"$RUN_ID"'",
      "test.run.status": "passed",
      "test.run.availability": 1,
      "test.run.duration_ms": 1500,
      "test.run.location": "us-east-1",
      "test.run.location.lat": 38.13,
      "test.run.location.lon": -78.45,
      "timestamp": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"
    },
    {
      "event.kind": "EXTERNAL_TEST_EVENT",
      "event.type": "external_test_step",
      "test.id": "my-first-test",
      "test.run.id": "'"$RUN_ID"'",
      "test.step.index": 1,
      "test.step.name": "load-homepage",
      "test.step.status": "passed",
      "test.step.duration_ms": 1500,
      "timestamp": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"
    }
  ]'
```

### Step 3 Verify ingestion

Query the raw events in Grail:

```
fetch events, from: -15m
| filter event.type == "external_test_run"
| fields timestamp, test.id, test.name, test.run.status, test.run.availability, test.run.duration_ms
| sort timestamp desc
```

If the query returns nothing, see [Troubleshooting](#troubleshooting).

### Step 4 Deploy the pipelines

Until a pipeline processes them, your events are searchable JSON and nothing more: no metrics, no Smartscape node, no alertable signal. Deploy the pipelines described in [OpenPipeline configuration](#openpipeline-configuration), either through OpenPipeline settings or with the [Monaco starter pack](#deploy-the-starter-pack-with-monaco).

Then confirm that metrics are flowing:

```
timeseries availability = avg(external.test.availability), by: { test.id }, from: -1h
```

### Step 5 Instrument your runner

Replace the curl call with an emitter in your test framework. Wrap your test so that every run produces one `external_test_run` event and one `external_test_step` event per step, batched into a single POST at the end of the run.

```javascript
const crypto = require('crypto');

const DT_ENDPOINT = process.env.DT_ENDPOINT;
const DT_TOKEN = process.env.DT_TOKEN;

const TEST_ID = 'test-checkout-flow-prod';
const TEST_NAME = 'Checkout Flow — Production';
const LOCATION = process.env.RUNNER_LOCATION || 'eu-west-1';

async function runTest(steps) {
  const runId = crypto.randomUUID();
  const runStart = Date.now();
  const events = [];

  let runStatus = 'passed';
  let runAvailability = 1;
  let runError = null;
  let runErrorCode = null;

  for (let i = 0; i < steps.length; i++) {
    const stepStart = Date.now();
    let stepStatus = 'passed';
    let stepError = null;
    let stepErrorCode = null;

    try {
      await steps[i].run();
    } catch (err) {
      stepStatus = 'failed';
      stepError = err.message;
      stepErrorCode = classify(err);     // e.g. NETWORK_ERROR, ASSERTION_FAILED
      runStatus = 'failed';
      runError = `Step ${i + 1}: ${err.message}`;
      runErrorCode = stepErrorCode;

      // Availability describes target reachability, not the overall test verdict.
      // Implement this helper for your framework and error taxonomy.
      if (isAvailabilityFailure(err, stepErrorCode)) runAvailability = 0;
    }

    events.push({
      'event.kind': 'EXTERNAL_TEST_EVENT',
      'event.type': 'external_test_step',
      'test.id': TEST_ID,
      'test.run.id': runId,
      'test.step.id': `step-${String(i + 1).padStart(3, '0')}`,
      'test.step.index': i + 1,
      'test.step.name': steps[i].name,
      'test.step.type': steps[i].type,
      'test.step.status': stepStatus,
      'test.step.duration_ms': Date.now() - stepStart,
      'test.step.error_message': stepError,
      'test.step.error_code': stepErrorCode,
      'timestamp': new Date(stepStart).toISOString(),
    });

    if (stepStatus === 'failed') break;  // stop on first failure
  }

  events.unshift({
    'event.kind': 'EXTERNAL_TEST_EVENT',
    'event.type': 'external_test_run',
    'test.id': TEST_ID,
    'test.name': TEST_NAME,
    'test.type': 'browser',
    'test.run.id': runId,
    'test.run.status': runStatus,
    'test.run.availability': runAvailability,
    'test.run.duration_ms': Date.now() - runStart,
    'test.run.location': LOCATION,
    'test.run.location.lat': 53.35,
    'test.run.location.lon': -6.26,
    'test.run.error_message': runError,
    'test.run.error_code': runErrorCode,
    'test.frequency_sec': 300,
    'dt.security_context': 'team-checkout',
    'dt.entity.application': process.env.DT_APPLICATION_ID,
    'dt.smartscape.frontend': process.env.DT_FRONTEND_ID,
    'ci.pipeline.id': process.env.CI_PIPELINE_ID,
    'ci.commit.sha': process.env.CI_COMMIT_SHA,
    'ci.branch': process.env.CI_BRANCH,
    'ci.trigger': 'schedule',
    'runner.name': 'playwright-wrapper',
    'runner.version': '1.4.0',
    'timestamp': new Date(runStart).toISOString(),
  });

  await fetch(DT_ENDPOINT, {
    method: 'POST',
    headers: {
      'Authorization': `Api-Token ${DT_TOKEN}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(events),
  });
}
```

> **Warning**
> Emit the events even when the run fails, and especially then. Use a `finally` block for handled failures and timeouts. A hard process or host failure can still prevent emission, so monitor reporting gaps separately.
>
> Keep `test.run.availability` independent from `test.run.status`. Implement `isAvailabilityFailure()` for your framework so network, DNS, TLS, or target-reachability failures set availability to `0`, while assertion and business-logic failures can remain available with a failed status.

---

## Event schema reference

Field names follow the `test.*` namespace. Two record types exist, distinguished by `event.type`.

> **Warning**
> Use these names exactly. The following names appear in earlier design drafts and in some third-party examples, but nothing in the pipeline routes or reads them: `monitor.id`, `synthetic.test.*`, `EXTERNAL_MONITOR`, and bare `test.run` / `test.step` as `event.type` values.

### Run event: `external_test_run`

#### Required

| Field | Type | Description |
| --- | --- | --- |
| `event.kind` | string | Always `EXTERNAL_TEST_EVENT`. Classifies the record and lets you scope queries to external tests. |
| `event.type` | string | Always `external_test_run`. Drives OpenPipeline routing. |
| `test.id` | string | Stable identifier of the test definition. Persists across executions; becomes the `EXT_TEST` Smartscape node ID and the primary dimension on every extracted metric. |
| `test.name` | string | Human-readable test name. Becomes the Smartscape node name and appears in Davis problem titles. |
| `test.run.id` | string | Unique identifier of this execution. A UUID is recommended. Used to join steps to their parent run. |
| `test.run.status` | string | One of `passed`, `failed`, `errored`, `timeout`, `maintenance`, `decommissioned`. |
| `test.run.availability` | number | `1` if the test considers the target available, `0` if not. |
| `test.run.duration_ms` | number | Total run duration in milliseconds. |

`timestamp` is recommended rather than required. Omit it and the platform stamps the record at
ingest time, which is correct for a runner that reports as soon as a test finishes. Send it and the
record carries the execution start instead, which is what you want if the runner batches results or
retries a delivery — every metric this pack extracts is a time series over that value, so the
alternative shifts your history to whenever delivery happened.

> **Warning**
> Backdating has a limit, and the limit differs by signal. An event is accepted up to **24 hours**
> old, but an **extracted metric** only up to **1 hour** old, and records outside the window are
> dropped rather than clamped. A runner more than an hour late therefore produces events you can
> query in Grail while the metric series has a hole — with no error to tell you. Keep the runner's
> clock in sync and upload within the hour. Timestamps more than 10 minutes in the future are
> clamped forward instead of dropped.

`test.run.status` and `test.run.availability` are deliberately separate. A run can be `failed` on a business assertion while the target is technically reachable. Set `availability` to reflect reachability, and use `status` plus `error_code` to express what actually went wrong.

The bundled `external.test.failures.by_code` processor counts only runs whose status is `failed`. The values `errored` and `timeout` remain valid for raw-event analysis, but they do not feed that metric with the supplied matcher. If those outcomes should contribute to the error-code spike detector, either normalize them to `failed` in the emitter and preserve the cause in `test.run.error_code`, or extend the matcher in your pipeline.

#### Recommended

| Field | Type | Description |
| --- | --- | --- |
| `timestamp` | string | ISO 8601 execution **start** time. Defaults to the ingest time if omitted. |
| `test.run.location` | string | Execution location label, for example `eu-west-1` or `gdansk-office`. Dimension on the availability, duration, and failure metrics; required for per-location outage detection. |
| `test.run.location_id` | string | Machine-readable location identifier, if your runner fleet has one distinct from the display label. |
| `test.run.location.lat` | number | Latitude of the runner in decimal degrees. Required by the geographic map tile on the Overview dashboard. |
| `test.run.location.lon` | number | Longitude of the runner in decimal degrees. |
| `test.type` | string | Test category, for example `browser`, `http`, `api`, `api-multi-step`, `grpc`, `mobile`, `trace-based`. Dimension on the availability metric. |
| `test.frequency_sec` | number | Scheduled interval in seconds. Omit for CI-gate runs that have no schedule. Used to compute error-budget arithmetic and maintenance duration. |
| `test.run.error_message` | string | Free-text error description for humans. |
| `test.run.error_code` | string | Short, aggregatable failure classifier, max 100 characters. Dimension on the failure-count metric. See [Error code taxonomy](#error-code-taxonomy). |
| `test.run.artifact_url` | string | Link to a trace viewer, HAR file, video, or screenshot archive. |
| `dt.security_context` | string | Data-segregation tag, for example `team-checkout`. Drives Grail access policies and per-team cost attribution. |
| `dt.entity.application` | string | Classic application entity ID (`APPLICATION-XXXXXXXXXXXXXXXX`). Extracted as a dimension on all run metrics. When present on every run, you can optionally set `dt.source_entity` in alert `eventTemplate` properties to anchor Davis problems to this application. Must be sent on every run or on none — a dimension that is null on some runs splits the metric series. |
| `dt.smartscape.frontend` | string | Smartscape frontend node ID (`FRONTEND-XXXXXXXXXXXXXXXX`). Required for the `EXT_TEST → FRONTEND` topology edge. |
| `frontend.name` | string | Optional human-readable frontend name stored for querying. It does not create a topology edge; send `dt.smartscape.frontend` to create the `EXT_TEST → FRONTEND` relationship. |

Discover the IDs you'll need:

```
smartscapeNodes "FRONTEND"
| filter contains(name, "<your-app>")
| fields id, name
```

```
fetch dt.entity.application
| filter contains(entity.name, "<your-app>")
| fields id, entity.name
```

#### Optional: CI/CD and runner context

| Field | Type | Description |
| --- | --- | --- |
| `ci.pipeline.id` | string | Pipeline run identifier |
| `ci.pipeline.name` | string | Pipeline name |
| `ci.commit.sha` | string | Commit under test |
| `ci.branch` | string | Branch name |
| `ci.trigger` | string | `schedule`, `deployment`, `manual`, or `ci` |
| `runner.name` | string | Runner implementation name. Extracted onto the Smartscape node. |
| `runner.version` | string | Runner version. Useful for correlating result changes with runner upgrades |
| `runner.instance.id` | string | Identifies the individual runner host or container |
| `test.run.mode` | string | `monitoring` or `load_test`. Lets a pipeline apply different processing to load-test traffic. |

### Step event: `external_test_step`

#### Required

| Field | Type | Description |
| --- | --- | --- |
| `event.kind` | string | Always `EXTERNAL_TEST_EVENT` |
| `event.type` | string | Always `external_test_step` |
| `test.id` | string | Denormalized from the parent run. Required: the pipeline uses it to stitch the step to its parent `EXT_TEST` node, and it saves a join on every step query. |
| `test.run.id` | string | Links the step to its parent run |
| `test.step.index` | number | One-based ordinal position of the step within the run |
| `test.step.name` | string | Human-readable step label. Dimension on the step-duration metric. Keep it stable across runs. |
| `test.step.status` | string | One of `passed`, `failed`, `errored`, `skipped` |
| `test.step.duration_ms` | number | Step duration in milliseconds |

#### Recommended

| Field | Type | Description |
| --- | --- | --- |
| `timestamp` | string | ISO 8601 step start time. Defaults to the ingest time if omitted. |
| `test.step.id` | string | Optional identifier of this step execution. Useful for external correlation, but not required by the bundled routing, metric extraction, or topology processing. |
| `test.step.type` | string | `navigation`, `click`, `api_call`, `assertion`, … |
| `test.step.url` | string | Target URL. Credentials in query parameters are masked by the pipeline, but sanitize at the source as well. |
| `test.step.error_message` | string | Error detail if the step failed: stack trace, failing selector, or assertion diff |
| `test.step.error_code` | string | Short failure classifier, max 100 characters |
| `test.step.screenshot_url` | string | Link to a screenshot artifact |
| `dt.security_context` | string | Data-segregation tag |

### Reserved fields set by OpenPipeline

Do not send these fields. The pipeline writes them, and a client-supplied value is either overwritten or corrupts topology stitching.

| Field | Written by | Value |
| --- | --- | --- |
| `dt.smartscape.ext_test` | Runs pipeline (Smartscape node extraction), steps pipeline (`fieldsAdd`) | Smartscape node ID derived from `test.id` |
| `result.status.category` | Steps pipeline (`fieldsAdd`) | `SUCCESS`, `SKIPPED`, or `FAIL`. Normalized step status for dashboard filtering |

### Error code taxonomy

`test.run.error_code` and `test.step.error_code` are free-form, but aggregation is only useful if the vocabulary is stable. Start from these technical codes:

| Code | Meaning |
| --- | --- |
| `TIMEOUT` | Operation exceeded its time budget |
| `ASSERTION_FAILED` | An assertion evaluated false |
| `LOCATOR_NOT_FOUND` | Element or selector not present |
| `NETWORK_ERROR` | Connection, DNS, or TLS failure |
| `AUTH_FAILED` | Authentication or authorization rejected |
| `RATE_LIMITED` | Throttled by the target |
| `UNEXPECTED_STATUS_CODE` | HTTP status outside the expected set |
| `JAVASCRIPT_ERROR` | Uncaught error in page context |

Add business-level codes with a distinguishing prefix, for example `BIZ_PAYMENT_DECLINED`, so technical and business failures remain separable in the failure-by-code metric.

> **Tip**
> Keep the cardinality of error codes bounded. `UNEXPECTED_STATUS_CODE` with the status in a separate field is better than `HTTP_500`, `HTTP_502`, `HTTP_503`, … as distinct codes, because every code becomes a metric dimension value.

---

## OpenPipeline configuration

Two pipelines process external test events: one for runs, one for steps. Splitting them keeps matchers simple and lets you evolve step processing independently. Steps are usually the higher-volume, lower-value stream.

Configuration types involved:

| Configuration | Settings schema | Scope |
| --- | --- | --- |
| Ingest source | `builtin:openpipeline.events.ingest-sources` | environment |
| Pipelines | `builtin:openpipeline.events.pipelines` | environment |
| Routing | `builtin:openpipeline.events.routing` | environment |
| Grail bucket | bucket definition | environment |

> **Warning**
> OpenPipeline routing is **global** configuration for the events scope. When you add routes, append to the existing table rather than replacing it. Replacing it removes routes that belong to other event producers.

### Routing

```json
{
  "routingEntries": [
    {
      "enabled": true,
      "description": "Route run-level events to the runs pipeline",
      "matcher": "event.type == \"external_test_run\"",
      "pipelineType": "custom",
      "pipelineId": "{{ .pipeline_runs_id }}"
    },
    {
      "enabled": true,
      "description": "Route step-level events to the steps pipeline",
      "matcher": "event.type == \"external_test_step\"",
      "pipelineType": "custom",
      "pipelineId": "{{ .pipeline_steps_id }}"
    }
  ]
}
```

`pipelineId` must resolve to the target pipeline's `customId`. The placeholders above are Monaco reference parameters. For details, see [Monaco specifics](#monaco-specifics). If you configure routing through the UI, select the pipeline rather than typing an ID.

### Runs pipeline

`customId`: `pipeline-external-test-runs`. Sections, in execution order: `processing`, `metricExtraction`, `smartscapeNodeExtraction`, `storage`.

#### Processing: mask credentials in URLs

```json
{
  "id": "mask-sensitive-urls",
  "description": "Mask credentials and tokens from step URLs",
  "type": "fieldsAdd",
  "matcher": "isNotNull(test.step.url)",
  "enabled": true,
  "fieldsAdd": {
    "fields": [
      {
        "name": "test.step.url",
        "value": "replacePattern(test.step.url, \"(?i)([?&])(token|access[_-]?token|api[_-]?key|key|password|passwd|secret|auth(?:orization)?|bearer(?:[_-]?token)?|session[_-]?id|sid|signature)=[^&]*\", \"$1$2=***MASKED***\")"
      }
    ]
  }
}
```

> **Warning**
> Treat this processor as a safety net, not the primary control. Sanitize URLs in the runner before the event is built: the pipeline cannot mask what it cannot pattern-match.

#### Smartscape node extraction

```json
{
  "id": "smartscape-ext-test-node",
  "description": "Register external test as a Smartscape node",
  "type": "smartscapeNode",
  "matcher": "event.type == \"external_test_run\"",
  "enabled": true,
  "smartscapeNode": {
    "nodeType": "EXT_TEST",
    "nodeIdFieldName": "dt.smartscape.ext_test",
    "idComponents": [
      { "idComponent": "field", "referencedFieldName": "test.id" }
    ],
    "extractNode": true,
    "nodeName": {
      "type": "field",
      "field": { "sourceFieldName": "test.name" }
    },
    "fieldsToExtract": [
      { "strategy": "equals", "fieldName": "test.type",           "referencedFieldName": "test.type" },
      { "strategy": "equals", "fieldName": "test.run.location",   "referencedFieldName": "test.run.location" },
      { "strategy": "equals", "fieldName": "dt.security_context", "referencedFieldName": "dt.security_context" },
      { "strategy": "equals", "fieldName": "runner.name",         "referencedFieldName": "runner.name" }
    ],
    "staticEdgesToExtract": [
      {
        "edgeType": "monitors",
        "targetType": "FRONTEND",
        "targetIdFieldName": "dt.smartscape.frontend"
      }
    ]
  }
}
```

Constraints to respect:

- A custom Smartscape node type must begin with `EXT_` or `CUSTOM_`.
- The node ID field name follows the pattern `dt.smartscape.<lowercased node type suffix>`, so `EXT_TEST` becomes `dt.smartscape.ext_test`.
- The edge to `FRONTEND` is only drawn if the runner supplies `dt.smartscape.frontend`. Classic `APPLICATION-*` IDs cannot be translated to `FRONTEND-*` IDs without a lookup table, because they belong to different entity systems.

> **Warning**
> Never name the node ID field `dt.entity.ext_test`. The `dt.entity.*` prefix is reserved for the classic entity model, where `EXT_TEST` does not exist. Such a dimension resolves to null even when the underlying field has a value.
>
> Use `dt.entity.*` only for `APPLICATION`, `SERVICE`, `HOST`, and other classic entity types.

#### Metric extraction

| Metric key | Processor type | Source | Dimensions |
| --- | --- | --- | --- |
| `external.test.availability` | `valueMetric` | `test.run.availability` | `test.id`, `test.name`, `test.run.location`, `test.type`, `dt.smartscape.ext_test`, `dt.entity.application` |
| `external.test.duration` | `valueMetric` | `test.run.duration_ms` | `test.id`, `test.name`, `test.run.location`, `dt.smartscape.ext_test`, `dt.entity.application` |
| `external.test.failures.by_code` | `counterMetric` | +1 per failed run with an error code | `test.id`, `test.run.error_code`, `test.run.location`, `dt.smartscape.ext_test`, `dt.entity.application` |
| `external.test.usage.events_ingested` | `counterMetric` | +1 per run event | `test.id`, `test.name`, `test.type`, `test.run.location`, `dt.smartscape.ext_test`, `dt.entity.application` |

```json
{
  "id": "extract-availability-metric",
  "description": "Extract per-test availability metric",
  "type": "valueMetric",
  "matcher": "event.type == \"external_test_run\" and test.run.status != \"maintenance\"",
  "enabled": true,
  "valueMetric": {
    "metricKey": "external.test.availability",
    "field": "test.run.availability",
    "dimensions": [
      { "extractionType": "field", "sourceFieldName": "test.id" },
      { "extractionType": "field", "sourceFieldName": "test.name" },
      { "extractionType": "field", "sourceFieldName": "test.run.location" },
      { "extractionType": "field", "sourceFieldName": "test.type" },
      { "extractionType": "field", "sourceFieldName": "dt.smartscape.ext_test" },
      { "extractionType": "field", "sourceFieldName": "dt.entity.application" }
    ]
  }
}
```

```json
{
  "id": "extract-failures-by-code-metric",
  "description": "Count failures grouped by error code",
  "type": "counterMetric",
  "matcher": "event.type == \"external_test_run\" and test.run.status == \"failed\" and isNotNull(test.run.error_code)",
  "enabled": true,
  "counterMetric": {
    "metricKey": "external.test.failures.by_code",
    "dimensions": [
      { "extractionType": "field", "sourceFieldName": "test.id" },
      { "extractionType": "field", "sourceFieldName": "test.run.error_code" },
      { "extractionType": "field", "sourceFieldName": "test.run.location" },
      { "extractionType": "field", "sourceFieldName": "dt.smartscape.ext_test" },
      { "extractionType": "field", "sourceFieldName": "dt.entity.application" }
    ]
  }
}
```

Three design decisions in these processors are worth carrying into your own configuration:

- **Maintenance runs are excluded from the availability metric** by the matcher `test.run.status != "maintenance"`. Planned downtime therefore never counts as unavailability or triggers an outage alert, while the raw maintenance events remain in Grail as an audit trail.
- **Dimension format.** Dimensions use `{"extractionType": "field", "sourceFieldName": "…"}`. The older form `{"name": "…", "value": "…"}` is rejected by the current schema.
- **`test.name` is intentionally absent from `external.test.failures.by_code`.** It's a counter split by error code and location, and adding the name would multiply cardinality for no analytical gain. Alerts on this metric reference `test.id` only.

> **Warning**
> Every field you want to alert on, split by, or use in a Davis problem title must be a dimension here. A dimension added later does not backfill.

#### Storage

```json
{
  "id": "store-to-external-tests-bucket",
  "description": "Store all run events in the external tests bucket for cost attribution",
  "type": "bucketAssignment",
  "matcher": "true",
  "enabled": true,
  "bucketAssignment": {
    "bucketName": "dynatrace-external-tests_events"
  }
}
```

Bucket definition:

```json
{
  "table": "events",
  "displayName": "External Tests",
  "retentionDays": 35
}
```

A dedicated bucket gives you three things: an independent retention period (35 days of raw events is usually enough, since metrics carry the long-term trend), isolated access permissions, and attributable retention cost. See [Cost and usage tracking](#cost-and-usage-tracking).

> **Warning**
> If you manage the bucket with Monaco, remember that Monaco prefixes bucket names with the project name. A bucket with `id: events` in project `dynatrace-external-tests` is created as `dynatrace-external-tests_events`, so the pipeline's `bucketAssignment` must use the full prefixed name. That is why the pipelines take the name as a `reference` parameter to the bucket config rather than spelling it out.
>
> An unresolvable bucket name is **silently ignored** and events keep landing in `default_events`.

### Steps pipeline

`customId`: `pipeline-external-test-steps`. Sections, in execution order: `processing`, `metricExtraction`, `storage`. There's no Smartscape extraction, because steps attach to the node created by the runs pipeline.

#### Processing

```json
{
  "id": "normalize-step-status",
  "description": "Normalize step status into a filterable category",
  "type": "fieldsAdd",
  "matcher": "event.type == \"external_test_step\"",
  "enabled": true,
  "fieldsAdd": {
    "fields": [
      {
        "name": "result.status.category",
        "value": "if(test.step.status == \"passed\", \"SUCCESS\", if(test.step.status == \"skipped\", \"SKIPPED\", \"FAIL\"))"
      }
    ]
  }
}
```

```json
{
  "id": "stitch-to-parent-node",
  "description": "Link step to its parent test run node in Smartscape",
  "type": "fieldsAdd",
  "matcher": "event.type == \"external_test_step\"",
  "enabled": true,
  "fieldsAdd": {
    "fields": [
      { "name": "dt.smartscape.ext_test", "value": "test.id" }
    ]
  }
}
```

The URL-masking processor from the runs pipeline is applied here as well.

#### Metric extraction

```json
{
  "id": "extract-step-duration-metric",
  "description": "Extract per-step duration metric",
  "type": "valueMetric",
  "matcher": "event.type == \"external_test_step\"",
  "enabled": true,
  "valueMetric": {
    "metricKey": "external.test.step.duration",
    "field": "test.step.duration_ms",
    "dimensions": [
      { "extractionType": "field", "sourceFieldName": "test.id" },
      { "extractionType": "field", "sourceFieldName": "test.step.name" },
      { "extractionType": "field", "sourceFieldName": "test.step.index" }
    ]
  }
}
```

#### Storage

Steps are assigned to the same bucket as runs, so retention and cost attribution stay aligned.

---

## Smartscape topology

Each unique `test.id` becomes an `EXT_TEST` node. That's what turns a Davis problem from "something is wrong in this environment" into "external test *Checkout Flow — Production* is unavailable".

Query nodes and edges with the dedicated DQL commands, **not** with `fetch`:

```
smartscapeNodes "EXT_TEST"
| fields id, name, test.type, test.run.location, dt.security_context, runner.name
```

```
smartscapeEdges "monitors"
| filter source_id == toSmartscapeId("EXT_TEST-XXXXXXXXXXXXXXXX")
| filter target_type == "FRONTEND"
| fields target_id, target_name = getNodeName(target_id)
```

Notes on the topology model:

- `fetch dt.entity.ext_test` fails with "entity type wasn't found". `EXT_TEST` and `FRONTEND` are Smartscape nodes, not classic entities.
- `smartscapeEdges` and `smartscapeNodes` are DQL *starting* commands, like `fetch`. Do not write `fetch smartscapeEdges`.
- Filter node IDs with `toSmartscapeId("EXT_TEST-…")`, not a bare string literal.
- `getNodeName(<id>)` resolves a node ID to its display name.
- Prefer edge traversal over reconstructing relationships from raw events. The edge is the same source of truth the topology map renders, it handles several frontends per test, and it doesn't depend on a query time window.

### Link problems to the node

Davis problems raised by the starter pack's anomaly detectors carry:

- `dt.smartscape_source.id` = `{dims:dt.smartscape.ext_test}`, which links the problem to the `EXT_TEST` node, so the Problems app shows the test as the affected entity instead of the environment.
- `dt.source_entity` (optional) = `{dims:dt.entity.application}`, which anchors the problem to a classic application entity. Omit it — or leave it absent — when the runner does not send `DT_APPLICATION_ID`. Davis then falls back to the ENVIRONMENT entity and still creates the problem. An empty string (what you get when the field is in `by: {}` but has no value) causes Davis to reject the event silently and create no problem at all.

> **Warning**
> `dt.smartscape_source.id` requires `dt.smartscape.ext_test` to be in the detector query's `by: {}` clause. `dt.source_entity` requires `dt.entity.application` — only add it when every run sends `DT_APPLICATION_ID`. A `{dims:x}` placeholder whose field is not grouped is rendered literally in the problem title.

---

## Alerting

Extracted metrics are alerted on with Davis anomaly detectors (`builtin:davis.anomaly-detectors`). The starter pack ships four, covering two different detection philosophies.

| Detector | Metric | Analyzer | Detects |
| --- | --- | --- | --- |
| Local outage | `external.test.availability` | Static threshold, `BELOW` | Sustained failure of one test in one location |
| Global outage | `external.test.availability` | Static threshold, `BELOW` | Failure of one test across all locations simultaneously |
| Performance anomaly | `external.test.duration` | Auto-adaptive baseline, `ABOVE` | Duration drifting above its learned baseline |
| Error code spike | `external.test.executions` (failures only) | Auto-adaptive baseline, `ABOVE` | A specific error code surging above its baseline |

### Local outage

```json
{
  "title": "External Test Local Outage",
  "description": "Fires when a test's availability stays below threshold in a single location.",
  "enabled": true,
  "source": "dynatrace-external-tests",
  "analyzer": {
    "name": "dt.statistics.ui.anomaly_detection.StaticThresholdAnomalyDetectionAnalyzer",
    "input": [
      { "key": "query", "value": "timeseries availability = avg(external.test.availability), interval:1m, by:{test.id, test.name, test.type, test.run.location, dt.smartscape.ext_test, dt.entity.application}" },
      { "key": "threshold", "value": "0.5" },
      { "key": "alertCondition", "value": "BELOW" },
      { "key": "alertOnMissingData", "value": "false" },
      { "key": "violatingSamples", "value": "5" },
      { "key": "slidingWindow", "value": "10" },
      { "key": "dealertingSamples", "value": "5" }
    ]
  },
  "eventTemplate": {
    "properties": [
      { "key": "event.name",              "value": "External test local outage: {dims:test.name}" },
      { "key": "event.description",       "value": "**{dims:test.name}** ({dims:test.id}) availability has been consistently below threshold — sustained outage detected.\n\nType: {dims:test.type} | Location: {dims:test.run.location}\n\nCheck runner health, CI pipeline status, and recent deployments for this test." },
      { "key": "event.type",              "value": "ERROR_EVENT" },
      { "key": "test.id",                 "value": "{dims:test.id}" },
      { "key": "test.name",               "value": "{dims:test.name}" },
      { "key": "test.type",               "value": "{dims:test.type}" },
      { "key": "test.run.location",       "value": "{dims:test.run.location}" },
      { "key": "dt.smartscape_source.id", "value": "{dims:dt.smartscape.ext_test}" }
    ]
  },
  "executionSettings": {}
}
```

To anchor problems to a classic application entity, add `{ "key": "dt.source_entity", "value": "{dims:dt.entity.application}" }` to the properties — but only when every run sends `DT_APPLICATION_ID`. An empty value causes Davis to reject the event silently.

`eventTemplate` carries no top-level `title`, `description`, or `eventType` keys. The problem name, description, and Davis event type are supplied as the `event.name`, `event.description`, and `event.type` entries of the `properties` array. They sit alongside the dimension properties.

### Global outage

Identical in structure, with five changes: `test.run.location` is removed from `by: {}`, the threshold drops to `0.1`, and `slidingWindow`, `violatingSamples`, and `dealertingSamples` drop to `5`, `3`, and `3`.

```
timeseries availability = avg(external.test.availability), interval:1m, by:{test.id, test.name, test.type, dt.smartscape.ext_test, dt.entity.application}
```

| Setting | Local outage | Global outage |
| --- | --- | --- |
| `by: {}` includes location | Yes: one series per test × location | No: one series per test, averaged over locations |
| `threshold` | `0.5` | `0.1` |
| `slidingWindow` | `10` | `5` |
| `violatingSamples` | `5` | `3` |
| `dealertingSamples` | `5` | `3` |

### Understand the thresholds

Removing `test.run.location` from `by: {}` is what makes a detector global: availability is then averaged across all locations reporting in that minute, and the threshold encodes *how many* locations must fail.

For a test running from three locations:

| Failing locations | Average availability | Fires at `0.5`? | Fires at `0.1`? |
| --- | --- | --- | --- |
| 1 of 3 | 0.67 | No | No |
| 2 of 3 | 0.33 | Yes | No |
| 3 of 3 | 0.00 | Yes | Yes |

So the local detector (with location in `by: {}`, one series per location) catches a single failing location. The global detector at `0.1` only fires when essentially everything is down. Pair them: the local detector routes to the team that owns the runner, and the global detector notifies the on-call responder.

Two further settings matter.

**`violatingSamples` out of `slidingWindow`** is expressed in aggregation intervals. With `interval: 1m`, `violatingSamples: 5` and `slidingWindow: 10`, a test must report failures for at least five minutes within a ten-minute window. Set this deliberately: it's your trade-off between alert latency and flapping.

> **Warning**
> **`alertOnMissingData: false`** means a location that stops reporting is not treated as failing. With `interval: 1m` and a test that runs less often than every five minutes, locations naturally land in different minute buckets, and penalizing missing data would produce constant false positives.
>
> Raise `interval` and `slidingWindow` to match your test cadence. A test that stops reporting altogether is not covered by these detectors — see [Limitations](#limitations).

### Performance anomaly

Auto-adaptive detectors learn a baseline instead of taking a fixed threshold, which suits tests whose duration varies with time of day or payload size.

```json
{
  "analyzer": {
    "name": "dt.statistics.ui.anomaly_detection.AutoAdaptiveAnomalyDetectionAnalyzer",
    "input": [
      { "key": "query", "value": "timeseries duration = avg(external.test.duration), interval:1m, by:{test.id, test.name, test.run.location, dt.smartscape.ext_test, dt.entity.application}" },
      { "key": "alertCondition", "value": "ABOVE" }
    ]
  },
  "eventTemplate": {
    "properties": [
      { "key": "event.name",              "value": "External test performance anomaly: {dims:test.name}" },
      { "key": "event.description",       "value": "**{dims:test.name}** ({dims:test.id}) duration is significantly above its learned baseline.\n\nLocation: {dims:test.run.location}\n\nCheck for slow dependencies, network latency, or recent changes that may have degraded performance." },
      { "key": "event.type",              "value": "PERFORMANCE_EVENT" },
      { "key": "test.id",                 "value": "{dims:test.id}" },
      { "key": "test.name",               "value": "{dims:test.name}" },
      { "key": "test.run.location",       "value": "{dims:test.run.location}" },
      { "key": "dt.smartscape_source.id", "value": "{dims:dt.smartscape.ext_test}" }
    ]
  }
}
```

Use `PERFORMANCE_EVENT` for degradation and `ERROR_EVENT` for unavailability. The event type determines how Davis classifies and correlates the resulting problem.

### Error code spike

```json
{
  "analyzer": {
    "name": "dt.statistics.ui.anomaly_detection.AutoAdaptiveAnomalyDetectionAnalyzer",
    "input": [
      { "key": "query", "value": "timeseries failures = sum(external.test.executions), filter:{test.run.status == \"failed\"}, interval:1m, by:{test.id, test.run.error_code, test.run.location, dt.smartscape.ext_test, dt.entity.application}" },
      { "key": "alertCondition", "value": "ABOVE" }
    ]
  },
  "eventTemplate": {
    "properties": [
      { "key": "event.name",              "value": "External test error code spike: {dims:test.run.error_code} on {dims:test.id}" },
      { "key": "event.description",       "value": "Sudden surge of **{dims:test.run.error_code}** failures detected for test **{dims:test.id}**.\n\nLocation: {dims:test.run.location}\n\nThis error code is firing significantly above its learned baseline. Check the target system, network path, or authentication configuration." },
      { "key": "event.type",              "value": "ERROR_EVENT" },
      { "key": "test.id",                 "value": "{dims:test.id}" },
      { "key": "test.run.error_code",     "value": "{dims:test.run.error_code}" },
      { "key": "test.run.location",       "value": "{dims:test.run.location}" },
      { "key": "dt.smartscape_source.id", "value": "{dims:dt.smartscape.ext_test}" }
    ]
  }
}
```

This detector catches a change in *failure mode* that an availability alert would miss, for example a test that was intermittently timing out and now returns `AUTH_FAILED` at the same overall availability.

### Notifications

The detectors raise standard Davis problems. Your existing notification configuration can route them when its matching rules include these problems. Filter on the problem title prefix (`External test …`) or on the `test.id` property.

---


## Maintenance windows

Failures during planned deployments should not consume error budget or trigger alerts. Three approaches, in order of preference:

**Send maintenance events (recommended).** The runner keeps its schedule but emits `test.run.status: "maintenance"` with `test.run.availability: 1`:

```json
{
  "event.kind": "EXTERNAL_TEST_EVENT",
  "event.type": "external_test_run",
  "test.id": "test-checkout-flow-prod",
  "test.name": "Checkout Flow — Production",
  "test.run.id": "…",
  "test.run.status": "maintenance",
  "test.run.availability": 1,
  "test.run.duration_ms": 0,
  "timestamp": "2026-08-19T14:00:00.000Z"
}
```

Metric extraction excludes `maintenance`, so availability stays clean. You keep an explicit audit trail and can distinguish maintenance from a runner that has stopped.

**Stop sending events.** It's the simplest approach: zero Dynatrace configuration and no impact on availability. However, a gap in the data is indistinguishable from a crashed runner, and it appears on the Usage dashboard as a test with no recent runs.

**Suppress alerts with a maintenance window.** No runner changes, but failures still reach metric extraction and still count against availability. Acceptable when the availability number does not matter for that test; otherwise avoid.

Audit how much time you spend in maintenance:

```
fetch events, from: -30d
| filter event.type == "external_test_run" and test.run.status == "maintenance"
| summarize
    maintenance_windows = count(),
    total_maintenance_minutes = sum(test.frequency_sec) / 60,
    by: { test.id, test.name }
| sort maintenance_windows desc
```

### Retire a test

When you remove a test permanently, send one final run event with `test.run.status: "decommissioned"`, `test.run.availability: 1`, and `test.run.duration_ms: 0`. This distinguishes an intentional retirement from a broken runner in the raw events, and leaves an audit record of who retired what and when. The `EXT_TEST` node then ages out once events stop arriving, and historical data in Grail is unaffected.

---

## Query your data

### Availability per test, last 24 hours

```
fetch events, from: -24h
| filter event.type == "external_test_run"
| summarize
    total = count(),
    passed = countIf(test.run.availability == 1),
    by: { test.id, test.name }
| fieldsAdd availability_pct = (toDouble(passed) / toDouble(total)) * 100
| sort availability_pct asc
```

### Availability and duration by location

```
fetch events, from: -24h
| filter event.type == "external_test_run"
| filter test.id == "test-checkout-flow-prod"
| summarize
    executions = count(),
    failures = countIf(test.run.availability == 0),
    avg_duration = avg(test.run.duration_ms),
    by: { test.run.location }
| fieldsAdd availability_pct = ((toDouble(executions) - toDouble(failures)) / toDouble(executions)) * 100
| sort availability_pct asc
```

### Top failing steps

```
fetch events, from: -7d
| filter event.type == "external_test_step" and test.step.status == "failed"
| summarize failure_count = count(), by: { test.id, test.step.name, test.step.index }
| sort failure_count desc
| limit 20
```

### Failure mode distribution

```
fetch events, from: -24h
| filter event.type == "external_test_run" and test.run.status == "failed"
| filter test.id == "test-checkout-flow-prod"
| summarize count = count(), by: { test.run.error_code }
| sort count desc
```

### P95 duration trend

```
timeseries p95_duration = percentile(external.test.duration, 95, rollup: avg),
  by: { test.id },
  filter: { test.id == "test-checkout-flow-prod" },
  interval: 1h
```

> **Warning**
> `percentile()`, `median()`, and `percentRank()` require an explicit `rollup:` parameter in a `timeseries` command. Without it, the query silently returns no data.

### Consecutive failure check

```
fetch events, from: -1h
| filter event.type == "external_test_run"
| filter test.id == "test-checkout-flow-prod"
| sort timestamp desc
| limit 3
| summarize
    sample_size = count(),
    failed = countIf(test.run.status == "failed"),
    last_status = takeFirst(test.run.status),
    last_timestamp = takeFirst(timestamp)
| filter sample_size == 3 and failed == sample_size
```

### X of Y locations failing

DQL has no `countDistinctIf` aggregate, so compute location ratios with two `summarize` stages.

```
fetch events, from: -15m
| filter event.type == "external_test_run"
| filter test.id == "test-checkout-flow-prod"
| summarize
    failures = countIf(test.run.availability == 0),
    by: { test.id, test.run.location }
| summarize
    locations_total = count(),
    locations_failing_twice = countIf(failures >= 2),
    by: { test.id }
| fieldsAdd ratio_failing = toDouble(locations_failing_twice) / toDouble(locations_total)
| filter ratio_failing >= 0.67
```

### Multi-location aggregation strategies

| Strategy | Aggregate | Behavior |
| --- | --- | --- |
| Strict: any location failing counts as an outage | `min(test.run.availability)` | Most sensitive; noisy with many locations |
| Majority: more than half must fail | two-stage `summarize`, as above | Balanced default |
| Lenient: all locations must fail | `max(test.run.availability)` | Ignores short regional failures; may miss real partial outages |

```
fetch events, from: -24h
| filter event.type == "external_test_run"
| filter test.id == "test-checkout-flow-prod"
| summarize availability = min(test.run.availability), by: { bin(timestamp, 5m) }
```

### Combine external tests with native synthetic monitors

DQL has no `union` command. Use `append`, normalizing dimension names on both sides first.

```
timeseries availability = avg(builtin:synthetic.browser.availability.location.total),
  by: { dt.smartscape.synthetic_test }, from: -24h
| fieldsAdd source = "native", source_id = dt.smartscape.synthetic_test
| fieldsRemove dt.smartscape.synthetic_test
| append [
    timeseries availability = avg(external.test.availability), by: { test.id }, from: -24h
    | fieldsAdd source = "external", source_id = test.id
    | fieldsRemove test.id
  ]
```

To discover the exact native metric key in your environment:

```
metrics
| filter contains(metric.key, "synthetic")
| summarize count(), by: { metric.key }
```

### Metrics are not a Grail table

There is no `fetch dt.metrics`. Query metrics with the `timeseries` command.

---

## Dashboards

The starter pack ships two dashboards. Each externalizes its tile queries so you can adapt them.

| Dashboard | Purpose | Key tiles |
| --- | --- | --- |
| Overview | Overall health of your test fleet | Availability, average duration, failed runs, active problems, availability honeycomb per test, availability heatmap per test and hour, duration by location and by test, geographic map |
| Usage | Run-event volume and retention usage | Events ingested per test, retained bytes per hour and per day |

The geographic map tile requires `test.run.location.lat` and `test.run.location.lon` on run events. These values are static per location: they describe where the runner is physically located, not what it tests. Without them, the tile renders empty.

---

## Cost and usage tracking

### Ingest volume

```
timeseries events = sum(external.test.usage.events_ingested),
  by: { test.id, test.name }, interval: 1h, from: -7d
```

### Retained bytes

Because both pipelines assign events to a dedicated bucket, `BILLING_USAGE_EVENT` records scoped to that bucket represent your external tests exclusively.

```
fetch dt.system.events
| filter event.kind == "BILLING_USAGE_EVENT"
    and event.type == "Events - Retain"
    and usage.bucket == "dynatrace-external-tests_events"
| makeTimeseries bytes = sum(toLong(billed_bytes)), interval: 1d
```

Convert to gigabytes:

```
fetch dt.system.events
| filter event.kind == "BILLING_USAGE_EVENT"
    and event.type == "Events - Retain"
    and usage.bucket == "dynatrace-external-tests_events"
| makeTimeseries bytes = sum(toLong(billed_bytes)), interval: 1h
| fieldsAdd total_gb = arraySum(bytes) / 1e9
| fields timeframe, interval, total_gb, bytes
```

> **Note**
> `Events - Ingest & Process` is **not** attributable to your bucket. Ingest is billed when the endpoint accepts the record, before OpenPipeline decides on a destination bucket, so that usage type always appears under `default_events`.
>
> Only `Events - Retain` is bucket-attributable. A dedicated bucket therefore measures your retention cost precisely, but it does not measure your ingest cost at all.

### Control cost

- **Right-size retention.** Extracted metrics carry aggregated long-term trends, while raw events retain detailed context. Keep raw events only as long as your investigation and compliance requirements require.
- **Emit steps selectively for high-volume tests.** Runs are the availability signal; steps are the diagnostic detail. For a test running every minute, consider emitting step events only for failed runs.
- **Represent load tests at run level.** Emit one `external_test_run` event per load-test execution with its verdict and summary duration. Send per-request throughput and latency as metrics; do not emit one external-test event per request or virtual-user iteration. Mark the summary with `test.run.mode: "load_test"` if you want a separate pipeline or short-retention bucket.
- **Use `dt.security_context`** to attribute usage per team.

---

## Deploy the starter pack with Monaco

The starter pack is Monaco configuration, so the whole setup is version-controlled and reviewable.

`manifest.yaml`:

```yaml
manifestVersion: "1.0"
projects:
  - name: dynatrace-external-tests
    path: .
environmentGroups:
  - name: default
    environments:
      - name: production
        url:
          type: environment
          value: DT_TENANT_URL
        auth:
          platformToken:
            name: PLATFORM_TOKEN
```

Environment variables:

| Variable | Value |
| --- | --- |
| `DT_TENANT_URL` | `https://<tenant>.apps.dynatrace.com` |
| `PLATFORM_TOKEN` | Platform token with the configuration scopes listed in [Token scopes](#token-scopes) |
| `DT_ENDPOINT` | `https://<environment-id>.live.dynatrace.com/platform/ingest/custom/events/external.tests` |
| `DT_TOKEN` | Platform token with `openpipeline:events.custom:ingest` |

Validate, then deploy:

```bash
monaco deploy manifest.yaml --dry-run
monaco deploy manifest.yaml
```

Configuration types in the project:

| Directory | Monaco type |
| --- | --- |
| `openpipeline/` | `builtin:openpipeline.events.ingest-sources`, `builtin:openpipeline.events.pipelines`, `builtin:openpipeline.events.routing` |
| `buckets/` | `bucket` |
| `custom-alerts/` | `builtin:davis.anomaly-detectors` |
| `dashboards/` | `document` (kind `dashboard`) |

### Monaco specifics

**Reference the pipeline, do not hardcode its ID.** The routing configuration's `pipelineId` must resolve to the target pipeline's `customId`. Use a reference parameter:

```yaml
- id: external-test-routing
  type:
    settings:
      schema: "builtin:openpipeline.events.routing"
      scope: "environment"
  config:
    name: "External Test Event Routing"
    template: routing.json
    parameters:
      pipeline_runs_id:
        type: reference
        configType: builtin:openpipeline.events.pipelines
        configId: external-test-pipeline-runs
        property: id
      pipeline_steps_id:
        type: reference
        configType: builtin:openpipeline.events.pipelines
        configId: external-test-pipeline-steps
        property: id
```

**Bucket names are prefixed with the project name.** A bucket with `id: events` in project `dynatrace-external-tests` becomes `dynatrace-external-tests_events`. Use the full name in `bucketAssignment`, or reference the bucket config so the name follows a project rename.

**Bucket config type is a flat string.** `type: bucket`, not `bucket: {}`. Requires Monaco 2.28.7 or later.

---

## Best practices

**Schema and naming**

- Keep `test.id` stable forever. It's the identity of the Smartscape node, the primary metric dimension, and the join key in every dashboard. Renaming it creates a new test and orphans the history of the old one.
- Keep `test.step.name` stable. It's a metric dimension, so renaming a step splits its duration series.
- Set `test.name` to something a responder will recognize immediately in a problem title.
- Put every field you might want to alert on into the metric dimensions from the start. Dimensions do not backfill.

**Reliability of the signal**

- Emit the run event from a `finally` block when the run fails or times out. A hard process or host failure can still prevent emission, so monitor reporting gaps separately.
- Give runners their own ingest tokens, one per team, so rotation and revocation have a bounded blast radius.
- Monitor reporting gaps as well as failures. The starter pack surfaces tests with no recent runs in the Usage dashboard, but it does not deploy a missing-run alert. Add a separate scheduled query or workflow if your operating model requires one.

**Security**

- Never put credentials, session tokens, or personal data in event fields. Pipeline masking is a safety net, not a control.
- Store screenshots and HAR files in a secured artifact store and reference them with short-lived URLs.
- Tag every event with `dt.security_context` to enable per-team access policies and cost attribution.
- Rotate ingest tokens on a defined cadence (90 days is a reasonable default).

**Alerting hygiene**

- Pair a per-location detector with a global one, routed to different audiences.
- Match `interval` and `slidingWindow` to your test cadence. A five-minute test cannot produce five one-minute violating samples.
- Prefer auto-adaptive baselines for duration and static thresholds for availability. Availability has a known-good value; latency does not.

---

## Limitations

| Area | Limitation |
| --- | --- |
| Alerting is opt-in | Ingesting events creates no problems by itself. Outage detection must be configured explicitly. The starter pack's anomaly detectors cover the common cases. |
| Metric latency | Extracted metrics must be published before a detector's scheduled query evaluates them, adding tens of seconds compared to reacting to the raw event directly. |
| Backdating differs by signal | An event is accepted up to 24 hours old, an extracted metric only up to 1 hour, and records outside the window are dropped rather than clamped. A runner more than an hour late leaves queryable events and a hole in the metric series, with no error raised. Future timestamps beyond 10 minutes are clamped forward instead. |
| No alert when a test goes silent | The outage detectors set `alertOnMissingData: false`, because at `interval: 1m` a sparse test would false-positive constantly. Turning it on in a coarser detector does not solve it either: `timeseries` returns no series at all once the last data point falls outside the sliding window, so there is nothing left for a missing-data rule to evaluate, and the detector can only fire in the narrow band before that happens. Silence is surfaced instead as a count on the Usage dashboard, and the query behind that tile is a starting point if you want to raise your own event. |
| Events API entity types | `EXT_TEST` and `FRONTEND` are Smartscape nodes and are rejected as Events API entity selectors. Target `APPLICATION-*` and link the node through `dt.smartscape_source.id`. |
| Frontend edge requires an explicit ID | The `EXT_TEST → FRONTEND` edge only exists if the runner sends `dt.smartscape.frontend`. Classic `APPLICATION-*` IDs cannot be converted to `FRONTEND-*` IDs without a lookup table. |
| Smartscape node type prefix | Custom node types must begin with `EXT_` or `CUSTOM_`. |
| `dt.entity.*` namespace | Reserved for classic entities. A dimension named `dt.entity.ext_test` always resolves to null. |
| Routing is global | Events routing is environment-wide configuration. Appending routes carelessly can remove routes owned by other producers. |
| Bucket-level cost visibility is partial | Only `Events - Retain` is attributable to a dedicated bucket. `Events - Ingest & Process` is always billed against `default_events`. |
| Retention bounds how far back you can query | A DQL query over raw events cannot look further back than the bucket's retention period. |
| Load tests | Per-request event ingestion is not a supported pattern at load-test volume. Send aggregated metrics and sample failures. |
| Smartscape node lifetime | Nodes extracted from events age out after a platform-defined period once events stop arriving. Historical data in Grail is unaffected. |

---

## Troubleshooting

**The POST returns 401 or 403**

Check the token scope. The runner token needs exactly `openpipeline:events.custom:ingest`; `events.ingest` and `openpipeline.events.custom` are not valid scope names. Confirm the header format is `Authorization: Api-Token <token>`.

**The POST returns 404**

The ingest URL is wrong. It must use the classic environment domain and the ingest source's `pathSegment`:

```
https://<environment-id>.live.dynatrace.com/platform/ingest/custom/events/external.tests
```

The platform domain (`<tenant>.apps.dynatrace.com`) does not serve ingest endpoints.

**The POST returns 202 but `fetch events` finds nothing**

Widen the timeframe: `timestamp` is the value you sent, so a clock-skewed runner can place records outside your query window. Then check whether the records landed in a different bucket than you expect, and confirm your query filters on the exact `event.type` values `external_test_run` / `external_test_step`.

**Events arrive but no metrics appear**

Routing is not matching, or metric extraction is not firing. Verify that the routing matcher string matches your `event.type` exactly. Then check the extraction matchers: the availability metric excludes `test.run.status == "maintenance"`, and the failure counter requires both `test.run.status == "failed"` and a non-null `test.run.error_code`.

**Events land in `default_events` instead of the dedicated bucket**

The `bucketAssignment` bucket name does not resolve. Dynatrace silently keeps the previous assignment rather than failing. With Monaco, remember the `{project}_{id}` prefix.

**Deployment fails with 403 on bucket creation**

The token needs `storage:bucket-definitions:read` and `storage:bucket-definitions:write`, and the deploying user must be in a group with the **Data Processing and Storage** policy.

**A Davis problem title contains a literal `{dims:test.name}`**

The referenced dimension is not in the detector query's `by: {}` clause. Every `{dims:x}` placeholder must correspond to a grouped dimension.

**An anomaly detector never fires**

Check three things in order: the metric has data (`timeseries` on the metric key), `violatingSamples` is achievable at your test cadence given `interval` and `slidingWindow`, and the threshold arithmetic is right for your location count. For the arithmetic, see [Understand the thresholds](#understand-the-thresholds). If an `ERROR_EVENT` produces no problem, try `AVAILABILITY_EVENT`.

**A Smartscape query fails with "entity type wasn't found"**

You used `fetch dt.entity.ext_test`. Use `smartscapeNodes "EXT_TEST"` instead, because Smartscape nodes are not classic entities.

**A `timeseries` query with `percentile()` returns nothing**

Add the required `rollup:` parameter.

---

## Related topics

- [Data flow in OpenPipeline](https://docs.dynatrace.com/docs/platform/openpipeline/concepts/data-flow)
- [Processing in OpenPipeline](https://docs.dynatrace.com/docs/platform/openpipeline/concepts/processing)
- [Ingest sources in OpenPipeline](https://docs.dynatrace.com/docs/platform/openpipeline/reference/api-ingestion-reference)
- [Organize data in Grail](https://docs.dynatrace.com/docs/platform/grail/organize-data)
- [Assign permissions in Grail](https://docs.dynatrace.com/docs/platform/grail/organize-data/assign-permissions-in-grail)
- [Smartscape on Grail — Semantic Dictionary](https://docs.dynatrace.com/docs/semantic-dictionary/model/smartscape)
- [Dynatrace Query Language](https://docs.dynatrace.com/docs/platform/grail/dynatrace-query-language)
