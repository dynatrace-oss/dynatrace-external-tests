#!/usr/bin/env bash
# basic-example.sh — Send one external test result, with the minimum fields.
#
# The smallest thing that proves ingest works. For the complete field set and a
# small estate reporting continuously, see full-example.sh.

set -euo pipefail

: "${DT_ENDPOINT:?Set DT_ENDPOINT, e.g. https://<env-id>.live.dynatrace.com/platform/ingest/custom/events/external.tests}"
: "${DT_TOKEN:?Set DT_TOKEN to a platform token with openpipeline:events.custom:ingest scope}"

RUN_ID="${1:-$(uuidgen 2>/dev/null || date +%s)}"

# Send run event
curl -X POST "$DT_ENDPOINT" \
  -H "Authorization: Api-Token $DT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"event.kind\": \"EXTERNAL_TEST_EVENT\",
    \"event.type\": \"external_test_run\",
    \"test.run.id\": \"$RUN_ID\",
    \"test.id\": \"my-first-test\",
    \"test.name\": \"My First Test\",
    \"test.type\": \"browser\",
    \"test.run.status\": \"passed\",
    \"test.run.availability\": 1,
    \"test.run.duration_ms\": 1500,
    \"test.run.location\": \"us-east-1\",
    \"test.run.location.lat\": 38.13,
    \"test.run.location.lon\": -78.45,
    \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"
  }"

echo ""

# Send a step event (optional — for per-step forensics)
curl -X POST "$DT_ENDPOINT" \
  -H "Authorization: Api-Token $DT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"event.kind\": \"EXTERNAL_TEST_EVENT\",
    \"event.type\": \"external_test_step\",
    \"test.run.id\": \"$RUN_ID\",
    \"test.id\": \"my-first-test\",
    \"test.step.name\": \"load-homepage\",
    \"test.step.index\": 0,
    \"test.step.status\": \"passed\",
    \"test.step.duration_ms\": 1500,
    \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"
  }"

echo ""
echo "Done. Check Dynatrace → Dashboards → 'External tests — Overview' in 1-2 minutes."
