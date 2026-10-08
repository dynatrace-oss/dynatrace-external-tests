# dynatrace-external-tests

**External tests** are checks that you run outside Dynatrace and report to Dynatrace as events. They can come from Playwright or Selenium suites, mobile or desktop test frameworks, protocol checks, load-test tools, or third-party synthetic monitoring products.

This Monaco bundle deploys the ingestion, processing, topology, alerting, and dashboard configuration needed to analyze those results in Dynatrace.


---

## Table of Contents

- [What you get](#what-you-get)
- [How it works](#how-it-works)
- [Quick install](#quick-install)
- [Using it](#using-it)
- [Repository structure](#repository-structure)
- [Event schema](#event-schema)
- [Token scopes](#token-scopes)
- [How this compares to legacy](#how-this-compares-to-legacy-3rd-party-synthetic-api)
- [Common questions](#common-questions)
- [Documentation](#documentation)
- [Contributing](#contributing)
- [License](#license)

---

## What you get

After deployment, your environment contains:

- A dedicated **custom ingest endpoint** at `/platform/ingest/custom/events/external.tests` for receiving test results as JSON events
- **OpenPipeline configuration** that masks sensitive URLs, extracts availability, duration, and failure metrics, and creates Smartscape nodes
- **Smartscape topology** that can link external tests to the frontends they exercise
- **Davis anomaly detectors** for local outages, global outages, performance degradation, and error-code spikes; resulting problems flow through your existing notification profiles (Slack, PagerDuty, email, Jira, and others)
- **Two dashboards**:
  - **Overview** for availability, run duration, failure causes, locations, and individual executions
  - **Usage** for run-event volume, retention usage, metric data points, and tests that have stopped reporting

Typical flow: deploy the bundle → configure your runner to send results → verify test nodes and dashboard data → receive Davis problems when failures meet the configured thresholds.

---

## How it works

```
your test runner                      Dynatrace
─────────────────                     ────────────────────────────────────────

[ Playwright/k6/  ]   HTTP POST       [ Custom Ingest Source              ]
[ Selenium/curl   ]──────────────────▶[ /platform/ingest/custom/events/    ]
[ runs your test  ]   JSON events     [   external.tests                   ]
                                      └────────────┬───────────────────────┘
                                                   │
                                                   ▼
                                      ┌──────────────────────────────────┐
                                      │ OpenPipeline                     │
                                      │  - Routes events by type         │
                                      │  - Extracts metrics              │
                                      │  - Creates Smartscape EXT_TEST   │
                                      │    nodes (+ FRONTEND edges)      │
                                      │  - Generates Davis signals       │
                                      │  - Masks sensitive URLs          │
                                      └────────────┬─────────────────────┘
                                                   │
                                ┌──────────────────┼──────────────────────┐
                                ▼                  ▼                      ▼
                      ┌────────────────┐ ┌────────────────┐ ┌─────────────────────┐
                      │ Custom Alerts  │ │ Smartscape     │ │ Dashboards          │
                      │ (Davis problem │ │ EXT_TEST node  │ │ (Overview, Usage)   │
                      │ when threshold │ │ + monitors     │ │                     │
                      │ is violated)   │ │ edge to        │ │                     │
                      │                │ │ FRONTEND       │ │                     │
                      └───────┬────────┘ └────────────────┘ └─────────────────────┘
                              │                                      ▲
                              ▼                                      │
                      ┌────────────────────────────────────┐         │
                      │ Davis Problem                      │─────────┘
                      │  - Routed via notification         │  Problem links to
                      │    profiles (Slack/PagerDuty/etc.) │  the Overview dashboard
                      │  - Visible in Problems UI          │
                      │  - Linked to affected nodes        │
                      └────────────────────────────────────┘
```

---

## Quick install

The fastest path from an empty environment to a deployed starter pack:

```bash
git clone https://github.com/Dynatrace/dynatrace-external-tests
cd dynatrace-external-tests
export DT_TENANT_URL=https://<your-tenant>.apps.dynatrace.com
export PLATFORM_TOKEN=<your-token>  # see Token scopes below
make deploy
```

After about 30 seconds, open Dynatrace, go to **Dashboards**, and search for **External tests** to confirm that the dashboards were deployed. They remain empty until a runner sends its first result.

To create an ingest token, send your first event, and configure alerts, continue with the [full walkthrough](docs/get-started.md).

---

## Using it

The [Get started guide](docs/get-started.md) is the single source of truth for using the starter pack. It covers prerequisites, deployment, sending your first result, understanding the data model, reading the dashboards, and adapting the alerts.

This README provides an overview of the repository and the configuration it deploys. For the complete schema, pipeline behavior, DQL examples, and troubleshooting guidance, see the [reference documentation](docs/reference.md).

---

## Repository structure

```
dynatrace-external-tests/
├── manifest.yaml                      # Tenant URL and auth (edit this before deploying)
├── delete.yaml                        # What `make delete` removes
├── Makefile                           # Convenience: make deploy/validate/delete
├── README.md
├── LICENSE
├── CONTRIBUTING.md
├── CODE_OF_CONDUCT.md
├── SECURITY.md
├── monaco/                            # Everything deployed by Monaco
│   ├── openpipeline/                  # Event ingestion and processing
│   │   ├── ingest-source.json
│   │   ├── routing.json
│   │   ├── pipeline-runs.json
│   │   └── pipeline-steps.json
│   ├── buckets/                       # Dedicated Grail bucket for test events
│   ├── custom-alerts/                 # Outage detection (Anomaly Detection)
│   │   ├── outage-detection-time-based/
│   │   │   ├── config.yaml            #     Alert instances (edit thresholds here)
│   │   │   ├── local-outage.json      #     Template: alert when ONE location fails
│   │   │   └── global-outage.json     #     Template: alert when ALL locations fail
│   │   ├── performance-anomaly/       #   Duration-based anomaly detection
│   │   └── error-code-spike/          #   Spike alerts on specific error categories
│   └── dashboards/                    # Pre-built dashboards
│       ├── external-tests-overview.dashboard.json
│       ├── external-tests-usage.dashboard.json
│       ├── overview/                  #   Tile queries and variables, one DQL file each
│       └── usage/
├── samples/                           # Runner samples (not deployed by Monaco)
│   ├── basic-example.sh               #   One result, minimum fields — proves ingest works
│   ├── full-example.sh                #   A small estate with every field the model uses
│   └── playwright-wrapper/
└── docs/                              # Deeper documentation
    ├── get-started.md                 # Full onboarding walkthrough
    ├── reference.md                   # Schema, OpenPipeline, alerting, query reference
    └── images/
```

---

## Event schema

Your runner posts a single JSON object, or an array of objects, to the ingest endpoint. This minimum run event is ready to adapt:

```json
{
  "event.kind": "EXTERNAL_TEST_EVENT",
  "event.type": "external_test_run",
  "test.run.id": "<unique-uuid>",
  "test.id": "<stable-id-for-this-test>",
  "test.name": "<human-readable-name>",
  "test.run.status": "passed",
  "test.run.availability": 1,
  "test.run.duration_ms": 4200
}
```

`test.run.status` accepts `passed`, `failed`, `errored`, `timeout`, `maintenance`, or `decommissioned`. Add `test.run.location` when you need per-location analysis or alerting.

If your runner does not report immediately after execution, add `timestamp` with the execution start time. If you omit it, Dynatrace timestamps the event at ingest. See the [event schema reference](docs/reference.md#event-schema-reference) for field requirements and timestamp limits.

Recommended fields for richer observability:

- `test.run.location` — execution location, such as `eu-west-1` or `gdansk-office`; enables per-location analysis and outage detection
- `test.run.error_message` — a short, human-readable failure description
- `test.run.error_code` — a stable category used to group and trend failures. Recommended values include `TIMEOUT`, `ASSERTION_FAILED`, `LOCATOR_NOT_FOUND`, `NETWORK_ERROR`, `AUTH_FAILED`, `RATE_LIMITED`, `UNEXPECTED_STATUS_CODE`, and `JAVASCRIPT_ERROR`
- `test.run.location.lat` / `test.run.location.lon` — decimal coordinates of the runner. These fields are required for the geographic map in the Overview dashboard and identify where the runner is located, not what it tests
- `test.type` — test category, for example `browser`, `http`, or `api-multi-step`
- `dt.security_context` — team or ownership context used for data-access policies and attribution
- `dt.smartscape.frontend` — Smartscape `FRONTEND-*` ID of the frontend exercised by the test. When present, OpenPipeline creates an `EXT_TEST → FRONTEND` topology edge. Find the ID with:

  ```dql
  smartscapeNodes "FRONTEND"
  | filter contains(name, "<your-app>")
  | fields id, name
  ```

- `dt.entity.application` — classic `APPLICATION-*` entity ID used to associate Davis problems with the affected application. Find the ID with:

  ```dql
  fetch dt.entity.application
  | filter contains(entity.name, "<your-app>")
  | fields id, entity.name
  ```

  Send `dt.entity.application` on every run of a test or omit it consistently. Sending it intermittently splits the extracted metric into separate series and can produce duplicate or incomplete problem data.

You can also send step-level events (`event.type: "external_test_step"`) to track individual step durations, screenshots, artifacts, and error codes.

See the [event schema reference](docs/reference.md#event-schema-reference) for the full schema, including trace correlation, CI context, runner metadata, and the recommended error-code taxonomy.

---

## Token scopes

Use separate credentials for deployment, ingestion, and anomaly detection. The runner token should not be able to read data or modify configuration:

**Deploy token** (used by `make deploy` / `monaco deploy`):
- `app-engine:apps:run`
- `document:documents:read`, `document:documents:write`, `document:documents:delete`, `document:trash.documents:delete`
- `settings:objects:read`, `settings:objects:write`
- `settings:objects:admin` (for OpenPipeline routing — global config)
- `settings:schemas:read`
- `openpipeline:configurations:read`, `openpipeline:configurations:write`
- `storage:bucket-definitions:read`, `storage:bucket-definitions:write` (for the Grail bucket)

**Runner token** (used by your tests to send events):
- `openpipeline:events.custom:ingest`

**Custom alert actor** (recommended: dedicated service user):
- `davis:analyzers:execute`
- `storage:events:read`
- `storage:metrics:read`
- `iam:service-users:use`

To limit write access to the required anomaly-detection schema, use a scoped policy:

```
ALLOW settings:schemas:read, settings:objects:write
WHERE settings:schemaId = "builtin:davis.anomaly-detectors";
```

See [Token scopes](docs/reference.md#token-scopes) in `docs/reference.md` for the full token guide.

---

## How this compares to legacy 3rd-party Synthetic API

| Aspect | Legacy 3rd-party Synthetic API | External Tests on Grail |
|---|---|---|
| Schema | Rigid (only availability, duration, error_message) | Flexible — any custom metadata, full context, error codes |
| Usage model | Per-monitor licensing | Grail event and metric usage — volume and major billing drivers are visible in the bundled Usage dashboard |
| Customization | Hardcoded outage detection rules | Parameterized via Monaco config |
| Integration | Direct API only | Standard events ingest, OpenPipeline, DQL analytics |
| Failure detail | Error message text only | Error message, plus an error-code category that becomes a metric dimension — failures group and trend by cause, and a spike in a single code alerts on its own |
| Data platform | Dedicated synthetic storage | Grail-native, queryable with DQL alongside the rest of your data |

If you're using the legacy API today, you can run both systems side-by-side — they don't interfere. Migrate at your own pace as you build confidence in the new model.

---

## Common questions

**Q: How does this differ from Dynatrace's native Synthetic Monitoring?**
Dynatrace Synthetic Monitoring schedules and executes browser, HTTP, and API tests from Dynatrace locations. **External Tests on Grail** is for tests executed by another tool, such as Playwright, k6, Selenium, a CI pipeline, or a third-party test platform. You keep the existing execution infrastructure and send the results to Dynatrace for analysis, topology, dashboards, and alerting.

**Q: What does this cost?**
Usage depends on the number and size of events you send, their retention, and the metric data points extracted by OpenPipeline. The bundled **External tests — Usage** dashboard shows run-event volume, attributable retention usage, metric data points, and estimated per-test billing drivers.

**Q: Can I send results from CI?**
Yes. The events API accepts JSON from anywhere — GitHub Actions, GitLab CI, Jenkins, your laptop. Add `ci.commit.sha`, `ci.branch`, `ci.pipeline.name` fields and they travel with the event, so you can query and chart them.

**Q: My tests run from CI, on demand, or once daily rather than on a regular schedule. Does this work?**
Yes, but tune the detectors to the test cadence. The default outage detectors evaluate one-minute intervals, so an infrequent test cannot produce enough violating samples to alert with the default settings. Adjust `interval` and `sliding_window` as described in [Tune an outage alert](docs/get-started.md#tune-an-outage-alert). The detectors do not alert when a runner stops reporting. The Usage dashboard lists tests with no run in the last two hours, but this fixed threshold can also include healthy daily or on-demand tests. See [Limitations](docs/reference.md#limitations).

**Q: My tests run from multiple locations. How does that work?**
Send one event per location and set `test.run.location`. The starter pack includes a local detector for failures in an individual location and a global detector that aggregates availability across locations. Adjust their thresholds and evaluation windows to match your outage policy.

**Q: Can I query both native Synthetic Monitoring data and my external test data in one dashboard?**
Yes, but it requires DQL `append` (there is no top-level `union` command in DQL) — the metric namespaces are deliberately separate (`builtin:synthetic.*` for native, `external.test.*` for this bundle). See [Combine external tests with native synthetic monitors](docs/reference.md#combine-external-tests-with-native-synthetic-monitors) in `docs/reference.md` for the unified query pattern.

**Q: How do I rotate the ingestion token?**
Generate a new token at [myaccount.dynatrace.com/platformTokens](https://myaccount.dynatrace.com/platformTokens) with the `openpipeline:events.custom:ingest` scope, update your runner config to use it, then revoke the old token.

**Q: I want to change a threshold. Where do I do it?**
Edit `monaco/custom-alerts/outage-detection-time-based/config.yaml` in your fork, redeploy. Or edit directly in the Anomaly Detection UI for ad-hoc changes (sync back to your repo afterwards).

**Q: What is the error code for? Do I have to use it?**
No. `test.run.error_code` is optional, but it makes failure analysis much more useful. `test.run.error_message` contains the human-readable detail, while the error code provides a stable category such as `TIMEOUT`, `ASSERTION_FAILED`, or `NETWORK_ERROR`. This lets dashboards group failures by cause and enables the bundled error-code spike detector. See [Event schema](#event-schema) for the recommended taxonomy.

**Q: What if I uninstall? Does Monaco clean up?**
Yes. Run `make delete` and all assets created from the bundle are removed. Your test event data in Grail remains (it's separate from configuration).

---

## Documentation

- **[docs/get-started.md](docs/get-started.md)** — full onboarding walkthrough: deploy, send your first result, read the dashboard, adapt the alerts
- **[docs/reference.md](docs/reference.md)** — schema, OpenPipeline configuration, Smartscape topology, alerting, trace correlation, and query reference

---

## Contributing

Issues and pull requests are welcome — see
[CONTRIBUTING.md](CONTRIBUTING.md) for the development setup and the checklist
to run through before opening a PR.

This is configuration that you deploy and manage in your own environment. It is published under [Apache-2.0](LICENSE) and maintained on a best-effort basis through this repository. See [SECURITY.md](SECURITY.md) for instructions on reporting a vulnerability.

### What's next

Once you have one test running:
- **Add more tests** — same payload, different `test.id`
- **Onboard your team** — fork the bundle repo, add per-team outage detection entries, redeploy
- **Connect to CI** — emit events from your deployment pipelines for canary checks
- **Tune outage rules** — start with defaults, adjust based on real failure patterns after 2-3 weeks
- **Add error code categorization** — populate `test.run.error_code` on failures so the error-code tiles and the spike alert have something to work with

---

## License

[Apache License 2.0](LICENSE)
