#!/usr/bin/env bash
# full-example.sh — Report a small test estate with the complete field set.
#
# basic-example.sh sends one minimal result, which proves ingest works. This one
# reports what a properly instrumented estate looks like: several tests, several
# locations, occasional failures with a cause attached. Run it to see what the
# data model gives you — availability over time, failures grouped by cause, one
# location degrading while the others hold — before wiring up a real runner.
#
# Usage:
#   DT_ENDPOINT=https://<env-id>.live.dynatrace.com/platform/ingest/custom/events/external.tests \
#   DT_TOKEN=<platform token with openpipeline:events.custom:ingest> \
#   ./samples/full-example.sh
#
# Optional:
#   INTERVAL           seconds between batches            (default: 30)
#   ITERATIONS         number of batches, 0 = run forever (default: 0)
#   FAIL_EVERY         fail one run every N batches       (default: 5)
#   SPIKE_ERROR_CODE   if set, failing runs use this code instead of random
#                      (one of TIMEOUT ASSERTION_FAILED LOCATOR_NOT_FOUND NETWORK_ERROR)
#   DT_APPLICATION_ID  APPLICATION-… to anchor Davis problems on   (default: unset)
#   DT_FRONTEND_ID     FRONTEND-… to link the test to a frontend   (default: unset)
#
# The two entity variables are dimensions on the availability metric. Send them on
# every run or on none: a dimension that is null on some runs drops out of the
# series key and splits one test into two independent series. Leave them unset if
# your test has no frontend.

set -uo pipefail

: "${DT_ENDPOINT:?Set DT_ENDPOINT, e.g. https://<env-id>.live.dynatrace.com/platform/ingest/custom/events/external.tests}"
: "${DT_TOKEN:?Set DT_TOKEN to a platform token with openpipeline:events.custom:ingest scope}"

INTERVAL="${INTERVAL:-30}"
ITERATIONS="${ITERATIONS:-0}"
FAIL_EVERY="${FAIL_EVERY:-5}"
SPIKE_ERROR_CODE="${SPIKE_ERROR_CODE:-}"
DT_APPLICATION_ID="${DT_APPLICATION_ID:-}"
DT_FRONTEND_ID="${DT_FRONTEND_ID:-}"

# test.id : test.name : test.type : steps (comma separated)
TESTS=(
  "checkout-flow:Checkout Flow:browser:open-homepage,add-to-cart,submit-payment"
  "api-health:API Health Check:api:auth-check,catalog-check"
  "mobile-login:Mobile Login:mobile:launch-app,enter-credentials"
)

# location : latitude : longitude — coordinates describe where the runner sits,
# not what it tests. The geographic map tile renders nothing without them.
LOCATIONS=(
  "us-east-1:38.13:-78.45"
  "eu-west-1:53.35:-6.26"
  "eu-central-1:50.11:8.68"
)

# Keep this list short: every distinct value becomes a metric dimension value.
ERROR_CODES=(TIMEOUT ASSERTION_FAILED LOCATOR_NOT_FOUND NETWORK_ERROR)

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
uuid()    { uuidgen 2>/dev/null || printf '%s-%s' "$(date +%s)" "$RANDOM"; }

entity_fields() {
  local out=""
  [[ -n "$DT_APPLICATION_ID" ]] && out+=",\"dt.entity.application\":\"$DT_APPLICATION_ID\""
  [[ -n "$DT_FRONTEND_ID"    ]] && out+=",\"dt.smartscape.frontend\":\"$DT_FRONTEND_ID\""
  printf '%s' "$out"
}

ci_trigger="manual"; [[ -n "${CI:-}" ]] && ci_trigger="ci"

batch=0
while :; do
  batch=$((batch + 1))
  fail_this_batch=0
  [[ "$FAIL_EVERY" -gt 0 && $((batch % FAIL_EVERY)) -eq 0 ]] && fail_this_batch=1

  for test_spec in "${TESTS[@]}"; do
    IFS=: read -r test_id test_name test_type steps <<< "$test_spec"

    for loc_spec in "${LOCATIONS[@]}"; do
      IFS=: read -r location lat lon <<< "$loc_spec"

      run_id="$(uuid)"
      ts="$(now_iso)"

      # checkout-flow at us-east-1 is consistently broken — availability stays at
      # 0 long enough to cross the local-outage detector's violatingSamples window.
      # Other tests at us-east-1 fail occasionally (1 in FAIL_EVERY batches) to
      # populate error-code charts without triggering an alert. All other locations
      # stay green so the dashboard shows a mix of healthy and degraded results.
      if [[ "$test_id" == "checkout-flow" && "$location" == "us-east-1" ]]; then
        status="failed"; availability=0
        error_code="ASSERTION_FAILED"
        error_message="Step assertion failed after 3 retries"
        duration=$((4000 + RANDOM % 4000))
      elif [[ "$fail_this_batch" -eq 1 && "$location" == "us-east-1" ]]; then
        status="failed"; availability=0
        if [[ -n "$SPIKE_ERROR_CODE" ]]; then
          error_code="$SPIKE_ERROR_CODE"
        else
          error_code="${ERROR_CODES[$((RANDOM % ${#ERROR_CODES[@]}))]}"
        fi
        error_message="Step assertion failed after $((RANDOM % 3 + 1)) retries"
        duration=$((4000 + RANDOM % 4000))
      else
        status="passed"; availability=1
        error_code=""; error_message=""
        duration=$((800 + RANDOM % 1200))
      fi

      run="{\"event.kind\":\"EXTERNAL_TEST_EVENT\",\"event.type\":\"external_test_run\"\
,\"test.id\":\"$test_id\",\"test.name\":\"$test_name\",\"test.type\":\"$test_type\"\
,\"test.run.id\":\"$run_id\",\"test.run.status\":\"$status\"\
,\"test.run.availability\":$availability,\"test.run.duration_ms\":$duration\
,\"test.run.location\":\"$location\",\"test.run.location.lat\":$lat,\"test.run.location.lon\":$lon\
,\"runner.name\":\"full-example\",\"runner.version\":\"1.0.0\"\
,\"ci.trigger\":\"$ci_trigger\",\"timestamp\":\"$ts\"$(entity_fields)"
      if [[ -n "$error_code" ]]; then
        run+=",\"test.run.error_code\":\"$error_code\",\"test.run.error_message\":\"$error_message\""
      fi
      run+="}"

      # Steps carry test.id so the pipeline can stitch them to the parent node.
      # They deliberately carry no location: step events have no location field,
      # and the step tiles say so.
      payload="[$run"
      idx=0
      IFS=, read -r -a step_names <<< "$steps"
      for step_name in "${step_names[@]}"; do
        idx=$((idx + 1))
        step_dur=$((duration / ${#step_names[@]}))
        step_status="passed"
        if [[ "$status" == "failed" && "$idx" -eq "${#step_names[@]}" ]]; then
          step_status="failed"
        fi
        payload+=",{\"event.kind\":\"EXTERNAL_TEST_EVENT\",\"event.type\":\"external_test_step\"\
,\"test.id\":\"$test_id\",\"test.run.id\":\"$run_id\"\
,\"test.step.id\":\"step-$(printf '%03d' "$idx")\",\"test.step.index\":$idx\
,\"test.step.name\":\"$step_name\",\"test.step.status\":\"$step_status\"\
,\"test.step.duration_ms\":$step_dur,\"timestamp\":\"$ts\"}"
      done
      payload+="]"

      code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$DT_ENDPOINT" \
        -H "Authorization: Api-Token $DT_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$payload")
      [[ "$code" == "202" ]] || echo "  HTTP $code for $test_id @ $location"
    done
  done

  echo "batch $batch sent ($(( ${#TESTS[@]} * ${#LOCATIONS[@]} )) runs$([[ $fail_this_batch -eq 1 ]] && echo ', with failures'))"
  [[ "$ITERATIONS" -gt 0 && "$batch" -ge "$ITERATIONS" ]] && break
  sleep "$INTERVAL"
done
