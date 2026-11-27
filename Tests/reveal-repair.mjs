import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';

const [phase, base, state, sessionFile, screenshots] = process.argv.slice(2);
assert.ok(['after-repair', 'after-restart'].includes(phase));
const runtime = process.cwd();
const load = file => import(pathToFileURL(path.join(runtime, file)).href);
const session = fs.readFileSync(sessionFile, 'utf8');
const policy = await fetch(base + '/api/admin/activity-retention', { headers: { cookie: 'switchboard_session=' + session } });
assert.equal(policy.status, 200);
const { hours, capture } = await policy.json();
assert.equal(hours, 9);
assert.deepEqual(capture, { available: true, reason: 'ready' });

// Feed a synthetic supported response through the real capture pipeline once.
// Use the existing supervisor binding rather than provisioning another store.
if (phase === 'after-repair') {
  const control = JSON.parse(fs.readFileSync(path.join(state, 'activity-preview-control.json'), 'utf8'));
  const binding = control.stores.find(entry => !entry.retired && !entry.pending);
  assert.ok(binding, 'The repaired supervisor did not bind preview storage');
  Object.assign(process.env, {
    SWITCHBOARD_ACTIVITY_PREVIEW_ROOT: binding.location,
    SWITCHBOARD_ACTIVITY_PREVIEW_INSTANCE: control.instance,
    SWITCHBOARD_ACTIVITY_PREVIEW_EPOCH: control.epoch,
    SWITCHBOARD_ACTIVITY_PREVIEW_STORE_ID: binding.storeId,
    SWITCHBOARD_ACTIVITY_PREVIEW_RESTORE_SAFE: '1',
    SWITCHBOARD_ACTIVITY_PREVIEW_EXCLUDED_ROOTS: JSON.stringify([process.env.SWITCHBOARD_DATA_DIR, state, runtime]),
  });
  const database = await load('server/db.ts');
  database.initDb();
  try {
    (await load('server/crypto.ts')).initKey();
    const owner = database.one("SELECT id FROM users WHERE username = 'synthetic-repair-owner'");
    assert.ok(owner);
    const { record } = await load('server/audit.ts');
    const output = await load('server/activity-output.ts');
    output.initOutputStore();
    const id = record({
      userId: owner.id,
      caller: { source: 'console', tokenId: null, tokenName: null, ip: null, userAgent: null },
      method: 'GET',
      url: 'https://api.example.test/desktop-repair-preview',
      status: 200,
    });
    await output.observeOutput(Response.json({ account_id: 'synthetic-repair-preview' }), id, owner.id,
      { fields: { account_id: { maxBytes: 128 } } }, []).text();
    assert.equal(output.readOutput(owner.id, id, false).state, 'retained');
  } finally {
    database.db.close();
  }
}
const { CDP, findBrowser } = await load('server/authentication-browser.ts');
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'switchboard-repair-edge-'));
const browser = new CDP(await findBrowser(undefined, 'chrome'), profile, { headless: true });
try {
  const tab = await browser.page('about:blank');
  await tab.call('Network.setCookie', { name: 'switchboard_session', value: session, url: base, httpOnly: true });
  await tab.call('Page.navigate', { url: base + '/activity?range=all' });
  const until = Date.now() + 30_000;
  async function waitFor(expression, description) {
    while (Date.now() < until) {
      const reply = await tab.call('Runtime.evaluate', { expression, returnByValue: true });
      if (reply.result?.value === true) return;
      await delay(100);
    }
    throw Error('Activity browser did not reach ' + description);
  }
  async function press(key, windowsVirtualKeyCode) {
    for (const type of ['keyDown', 'keyUp']) {
      await tab.call('Input.dispatchKeyEvent', { type, key, code: key === ' ' ? 'Space' : key, windowsVirtualKeyCode });
    }
  }
  await waitFor(`(() => {
    const row = [...document.querySelectorAll('tbody tr')].find(row => row.textContent.includes('/desktop-repair-preview'));
    if (!row) return false;
    row.focus();
    return document.activeElement === row;
  })()`, 'keyboard focus on the captured row');
  await press('Enter', 13);
  await waitFor(`(() => {
    const button = [...document.querySelectorAll('dialog button')].find(button => button.textContent.trim() === 'View output');
    if (!button) return false;
    button.focus();
    return document.activeElement === button;
  })()`, 'the View output button');
  await press(' ', 32);
  await waitFor(`[...document.querySelectorAll('dialog pre')].some(pre => pre.textContent.includes('synthetic-repair-preview'))`, 'the revealed preview');
  fs.mkdirSync(screenshots, { recursive: true });
  const { data } = await tab.call('Page.captureScreenshot', { format: 'png' });
  fs.writeFileSync(path.join(screenshots, 'activity-' + phase + '.png'), Buffer.from(data, 'base64'));
  await press('Escape', 27);
  await waitFor(`!document.querySelector('dialog[open]') && document.activeElement?.getAttribute('aria-label') === 'View GET details'`, 'focus returning to the activity row');
  console.log('PASS: Chromium revealed current preview with keyboard and restored row focus ' + phase);
} finally {
  await browser.close();
  await fs.promises.rm(profile, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 });
}
