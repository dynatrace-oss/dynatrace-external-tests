# Playwright Wrapper — External Tests

Runs a Playwright browser test and sends the result to Dynatrace External Tests on Grail.

## Prerequisites

```bash
npm install
npx playwright install chromium
```

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `DT_ENDPOINT` | Yes | Full ingest URL, e.g. `https://<tenant>.live.dynatrace.com/platform/ingest/custom/events/external.tests` |
| `DT_TOKEN` | Yes | Platform token with `openpipeline:events.custom:ingest` scope |
| `TEST_ID` | No | Stable identifier for the test (default: `test-checkout-flow-prod`) |
| `TEST_NAME` | No | Human-readable name shown in dashboards (default: `Checkout Flow — Production`) |
| `RUNNER_LOCATION` | No | Location label, e.g. `us-east-1`, `ci-github-actions` (default: `local`) |

## Usage

```bash
export DT_ENDPOINT="https://<tenant>.live.dynatrace.com/platform/ingest/custom/events/external.tests"
export DT_TOKEN="dt0s01.XXXX..."
export TEST_ID="checkout-flow-prod"
export TEST_NAME="Checkout Flow — Production"
export RUNNER_LOCATION="us-east-1"

npm test
```

## Adding Steps

Edit `runner.js` and add entries to the `steps` array following the existing pattern. Each step receives the shared `page` and `traceId`, sets the `traceparent` header, and returns a span ID.

## CI Integration

Set `CI=true` in your environment (most CI systems do this automatically) to tag events with `ci.trigger: ci` instead of `manual`.
