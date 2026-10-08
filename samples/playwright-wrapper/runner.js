'use strict';
const { chromium } = require('playwright');
const crypto = require('crypto');
const { v4: uuidv4 } = require('uuid');
const axios = require('axios');

const DT_ENDPOINT = process.env.DT_ENDPOINT;
const DT_TOKEN = process.env.DT_TOKEN;
const TEST_ID = process.env.TEST_ID || 'test-checkout-flow-prod';
const TEST_NAME = process.env.TEST_NAME || 'Checkout Flow — Production';
const LOCATION = process.env.RUNNER_LOCATION || 'local';
const RUNNER_NAME = 'playwright-wrapper';
const RUNNER_VERSION = '1.0.0';

if (!DT_ENDPOINT || !DT_TOKEN) {
  console.error('ERROR: DT_ENDPOINT and DT_TOKEN environment variables are required.');
  process.exit(1);
}

function genTraceId() { return crypto.randomBytes(16).toString('hex'); }
function genSpanId()  { return crypto.randomBytes(8).toString('hex'); }

function categorizeError(err) {
  const msg = err.message || '';
  if (/timeout/i.test(msg))             return 'TIMEOUT';
  if (/locator|selector|element/i.test(msg)) return 'LOCATOR_NOT_FOUND';
  if (/assertion|expect/i.test(msg))    return 'ASSERTION_FAILED';
  if (/network|dns|connection/i.test(msg)) return 'NETWORK_ERROR';
  if (/auth|401|403/i.test(msg))        return 'AUTH_FAILED';
  if (/429|rate.limit/i.test(msg))      return 'RATE_LIMITED';
  if (/5\d\d|unexpected.*status/i.test(msg)) return 'UNEXPECTED_STATUS_CODE';
  return 'ASSERTION_FAILED';
}

async function runExternalTest() {
  const traceId  = genTraceId();
  const runId    = uuidv4();
  const runSpanId = genSpanId();
  const startTime = new Date();
  const events = [];

  let runStatus = 'passed';
  let runError  = null;
  let runErrorCode = null;

  const browser = await chromium.launch();
  try {
    const page    = await browser.newPage();

    const steps = [
      { name: 'Navigate to homepage', fn: async () => {
          const stepSpanId = genSpanId();
          await page.setExtraHTTPHeaders({ traceparent: `00-${traceId}-${stepSpanId}-01` });
          await page.goto('https://example.com');
          return stepSpanId;
      }},
      // Add more steps here following the same pattern
    ];

    for (let i = 0; i < steps.length; i++) {
      const stepStart   = Date.now();
      let stepStatus    = 'passed';
      let stepError     = null;
      let stepErrorCode = null;
      let stepSpanId    = genSpanId();

      try {
        stepSpanId = await steps[i].fn();
      } catch (err) {
        stepStatus    = 'failed';
        stepError     = err.message;
        stepErrorCode = categorizeError(err);
        runStatus     = 'failed';
        runError      = `Step ${i + 1} (${steps[i].name}): ${err.message}`;
        runErrorCode  = stepErrorCode;
      }

      events.push({
        'event.kind':           'EXTERNAL_TEST_EVENT',
        'event.type':           'external_test_step',
        'test.id':              TEST_ID,
        'test.run.id':          runId,
        'test.step.id':         `step-${String(i + 1).padStart(3, '0')}`,
        'test.step.index':      i + 1,
        'test.step.name':       steps[i].name,
        'test.step.status':     stepStatus,
        'test.step.duration_ms': Date.now() - stepStart,
        ...(stepError     && { 'test.step.error_message': stepError }),
        ...(stepErrorCode && { 'test.step.error_code':    stepErrorCode }),
        'trace.id':             traceId,
        'span.id':              stepSpanId,
        'timestamp':            new Date(stepStart).toISOString(),
      });

      if (stepStatus === 'failed') break;
    }

  } finally {
    await browser.close();
  }

  events.unshift({
    'event.kind':             'EXTERNAL_TEST_EVENT',
    'event.type':             'external_test_run',
    'test.id':                TEST_ID,
    'test.name':              TEST_NAME,
    'test.type':              'browser',
    'test.run.id':            runId,
    'test.run.status':        runStatus,
    'test.run.duration_ms':   Date.now() - startTime.getTime(),
    'test.run.availability':  runStatus === 'passed' ? 1 : 0,
    'test.run.location':      LOCATION,
    ...(runError     && { 'test.run.error_message': runError }),
    ...(runErrorCode && { 'test.run.error_code':    runErrorCode }),
    'trace.id':               traceId,
    'span.id':                runSpanId,
    'ci.trigger':             process.env.CI ? 'ci' : 'manual',
    'runner.name':            RUNNER_NAME,
    'runner.version':         RUNNER_VERSION,
    'timestamp':              startTime.toISOString(),
  });

  const res = await axios.post(DT_ENDPOINT, events, {
    headers: {
      'Authorization': `Api-Token ${DT_TOKEN}`,
      'Content-Type':  'application/json',
    },
  });

  console.log(`Ingest accepted with HTTP ${res.status}.`);
  console.log(`Test ${TEST_ID} completed: ${runStatus} (${events[0]['test.run.duration_ms']}ms)`);
}

runExternalTest().catch(err => {
  if (err.response) {
    console.error(`Runner failed: ingest returned HTTP ${err.response.status}`);
    console.error(JSON.stringify(err.response.data));
  } else {
    console.error('Runner failed:', err.message);
  }
  process.exit(1);
});
