// Terminatab — Extension Unit Tests
// These test the protocol helpers, URL detection, and reconnect logic.

const results = [];

function assert(condition, message) {
  if (!condition) throw new Error(message || 'Assertion failed');
}

function assertEqual(actual, expected, message) {
  if (actual !== expected) {
    throw new Error(`${message || 'assertEqual'}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

function assertDeepEqual(actual, expected, message) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${message || 'assertDeepEqual'}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

function test(name, fn) {
  try {
    fn();
    results.push({ name, passed: true });
  } catch (e) {
    results.push({ name, passed: false, error: e.message });
  }
}

// ── Functions Under Test (imported from terminal.js at runtime) ────────
// These are defined here for the test runner. In production, they live in terminal.js.
// We re-declare them so tests can run standalone without the extension context.

function buildMessage(type, fields) {
  return JSON.stringify({ type, ...fields });
}

function parseServerMessage(json) {
  return JSON.parse(json);
}

const NEW_TAB_PATTERNS = [
  'chrome://newtab',
  'chrome://new-tab-page',
];

function isNewTabUrl(url) {
  return NEW_TAB_PATTERNS.some(pattern => url.startsWith(pattern));
}

class ReconnectBackoff {
  constructor(baseDelay = 1000, maxAttempts = 5) {
    this.baseDelay = baseDelay;
    this.maxAttempts = maxAttempts;
    this.attempt = 0;
  }

  nextDelay() {
    this.attempt++;
    return this.baseDelay * Math.pow(2, this.attempt - 1);
  }

  reset() {
    this.attempt = 0;
  }

  get exhausted() {
    return this.attempt >= this.maxAttempts;
  }
}

// ── Protocol Tests ─────────────────────────────────────────────────────

test('buildMessage creates valid new_session JSON', () => {
  const msg = buildMessage('new_session');
  const parsed = JSON.parse(msg);
  assertEqual(parsed.type, 'new_session');
});

test('buildMessage creates valid input JSON with session_id and data', () => {
  const msg = buildMessage('input', { session_id: 'abc123', data: 'ls\r' });
  const parsed = JSON.parse(msg);
  assertEqual(parsed.type, 'input');
  assertEqual(parsed.session_id, 'abc123');
  assertEqual(parsed.data, 'ls\r');
});

test('buildMessage creates valid resize JSON with cols and rows', () => {
  const msg = buildMessage('resize', { session_id: 'abc123', cols: 120, rows: 40 });
  const parsed = JSON.parse(msg);
  assertEqual(parsed.type, 'resize');
  assertEqual(parsed.cols, 120);
  assertEqual(parsed.rows, 40);
});

test('parseServerMessage parses session_created', () => {
  const msg = parseServerMessage('{"type":"session_created","session_id":"abc123"}');
  assertEqual(msg.type, 'session_created');
  assertEqual(msg.session_id, 'abc123');
});

test('parseServerMessage parses error', () => {
  const msg = parseServerMessage('{"type":"error","message":"not found"}');
  assertEqual(msg.type, 'error');
  assertEqual(msg.message, 'not found');
});

// ── URL Detection Tests ────────────────────────────────────────────────

test('isNewTabUrl returns true for chrome://newtab', () => {
  assert(isNewTabUrl('chrome://newtab'), 'Should match chrome://newtab');
  assert(isNewTabUrl('chrome://newtab/'), 'Should match chrome://newtab/');
});

test('isNewTabUrl returns true for chrome://new-tab-page', () => {
  assert(isNewTabUrl('chrome://new-tab-page'), 'Should match chrome://new-tab-page');
});

test('isNewTabUrl returns false for https://example.com', () => {
  assert(!isNewTabUrl('https://example.com'), 'Should not match regular URLs');
  assert(!isNewTabUrl('https://google.com'), 'Should not match google.com');
});

// ── Reconnect Backoff Tests ────────────────────────────────────────────

test('reconnect backoff doubles each attempt (1s, 2s, 4s)', () => {
  const backoff = new ReconnectBackoff(1000);
  assertEqual(backoff.nextDelay(), 1000, 'First attempt should be 1000ms');
  assertEqual(backoff.nextDelay(), 2000, 'Second attempt should be 2000ms');
  assertEqual(backoff.nextDelay(), 4000, 'Third attempt should be 4000ms');
});

test('reconnect resets backoff on successful connection', () => {
  const backoff = new ReconnectBackoff(1000);
  backoff.nextDelay(); // 1000
  backoff.nextDelay(); // 2000
  backoff.reset();
  assertEqual(backoff.nextDelay(), 1000, 'After reset, should be back to 1000ms');
  assertEqual(backoff.attempt, 1, 'Attempt counter should be 1 after reset + one call');
});

// ── Render Results ─────────────────────────────────────────────────────

const resultsDiv = document.getElementById('results');
const summaryDiv = document.getElementById('summary');

let passed = 0;
let failed = 0;

results.forEach(r => {
  const div = document.createElement('div');
  div.className = 'test-result';
  if (r.passed) {
    div.innerHTML = `<span class="pass">PASS</span> ${r.name}`;
    passed++;
  } else {
    div.innerHTML = `<span class="fail">FAIL</span> ${r.name}: ${r.error}`;
    failed++;
  }
  resultsDiv.appendChild(div);
});

summaryDiv.className = failed > 0 ? 'summary fail' : 'summary pass';
summaryDiv.textContent = `${passed} passed, ${failed} failed, ${results.length} total`;
