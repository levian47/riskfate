// Browser verification only; no npm packages or game-side JavaScript.
import { spawn } from 'node:child_process';
import { mkdir, writeFile } from 'node:fs/promises';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';

const url = process.argv[2];
assert(url?.startsWith('https://levian47.github.io/riskfate/') || url === 'http://127.0.0.1:8000/');
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const output = '/tmp/riskfate-browser-check';
await mkdir(output, { recursive: true });
for (const name of ['index.html', 'index.js', 'index.wasm', 'index.pck']) {
  const response = await fetch(new URL(name, url));
  assert.equal(response.status, 200, name);
  const bytes = Buffer.from(await response.arrayBuffer());
  assert(bytes.length > 0, name + ' is empty');
  if (name.endsWith('.wasm')) {
    assert.equal(bytes.subarray(0, 4).toString('hex'), '0061736d');
    assert(response.headers.get('content-type')?.includes('application/wasm'));
  }
  if (name.endsWith('.pck')) assert.equal(bytes.subarray(0, 4).toString(), 'GDPC');
  console.log('PASS: Web file', name, bytes.length, response.headers.get('content-type'));
}

const chrome = spawn('google-chrome', [
  '--headless=new', '--no-sandbox', '--disable-dev-shm-usage',
  '--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader',
  '--remote-debugging-port=9222', '--user-data-dir=/tmp/riskfate-chrome', 'about:blank'
], { stdio: ['ignore', 'ignore', 'ignore'] });
let socket;
try {
  let pages;
  for (let attempt = 0; attempt < 60; attempt++) {
    try { pages = await (await fetch('http://127.0.0.1:9222/json/list')).json(); break; }
    catch { await pause(250); }
  }
  assert(pages?.length, 'Chrome remote debugging did not start');
  socket = new WebSocket(pages.find(page => page.type === 'page').webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    socket.addEventListener('open', resolve, { once: true });
    socket.addEventListener('error', reject, { once: true });
  });
  const pending = new Map();
  const errors = [];
  let sequence = 0;
  socket.addEventListener('message', event => {
    const message = JSON.parse(event.data);
    if (message.id) {
      const request = pending.get(message.id);
      if (!request) return;
      pending.delete(message.id);
      clearTimeout(request.timer);
      if (message.error) request.reject(new Error(JSON.stringify(message.error)));
      else request.resolve(message.result);
    } else if (message.method === 'Runtime.exceptionThrown') {
      errors.push(JSON.stringify(message.params));
    } else if (message.method === 'Runtime.consoleAPICalled' && message.params.type === 'error') {
      errors.push(message.params.args.map(value => value.value ?? value.description).join(' '));
    }
  });
  function call(method, params = {}) {
    return new Promise((resolve, reject) => {
      const id = ++sequence;
      const timer = setTimeout(() => { pending.delete(id); reject(new Error('CDP timeout: ' + method)); }, 30000);
      pending.set(id, { resolve, reject, timer });
      socket.send(JSON.stringify({ id, method, params }));
    });
  }
  async function evaluate(expression) {
    const result = await call('Runtime.evaluate', { expression, returnByValue: true });
    assert(!result.exceptionDetails, JSON.stringify(result.exceptionDetails));
    return result.result.value;
  }
  async function screenshot(name, inline = false) {
    await pause(200);
    const { data } = await call('Page.captureScreenshot', { format: 'png' });
    if (name) await writeFile(output + '/' + name + '.png', Buffer.from(data, 'base64'));
    if (name === 'cycled') console.log('RF_CYCLED_SCREENSHOT_BASE64:' + data);
    return inline ? data : createHash('sha256').update(Buffer.from(data, 'base64')).digest('hex');
  }
  async function tap(x, y) {
    await call('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x, y }] });
    await pause(80);
    await call('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
    await pause(150);
    await call('Input.dispatchMouseEvent', { type: 'mouseMoved', x: 0, y: 0 });
    await pause(80);
  }
  await call('Page.enable');
  await call('Runtime.enable');
  await call('Emulation.setTouchEmulationEnabled', { enabled: true });
  await call('Emulation.setDeviceMetricsOverride', { width: 480, height: 800, deviceScaleFactor: 1, mobile: true });
  await call('Page.navigate', { url });
  let started = false;
  for (let attempt = 0; attempt < 120; attempt++) {
    started = await evaluate("!!document.getElementById('canvas') && !document.getElementById('status')");
    if (started || errors.length) break;
    await pause(500);
  }
  assert(started, 'Godot did not finish loading: ' + errors.join('\n'));
  assert.equal(await evaluate('GODOT_THREADS_ENABLED'), false, 'single-thread Web build');
  await pause(500);
  console.log('PASS: Godot loaded in Chrome using the official shell without cross-origin isolation');

  // At DPR 1 the world and UI use native canvas pixels. Cycle directions at rest.
  const initial = await screenshot('initial');
  await tap(256, 80);
  assert.notEqual(await screenshot(), initial, 'stationary direction button changes frame');
  for (let index = 0; index < 7; index++) await tap(256, 80);
  assert.equal(await screenshot('cycled'), initial, 'eight stationary turns return to original frame');

  // Exercise held touch, off-pad drag, release, and held keyboard.
  const movingStart = await screenshot();
  await call('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: 34, y: 654 }] });
  await pause(300);
  assert.notEqual(await screenshot(), movingStart, 'held touch moves/faces the hero');
  await call('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [{ x: 250, y: 600 }] });
  await call('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
  const stopped = await screenshot();
  assert.equal(await screenshot(), stopped, 'release outside pad stops motion');
  await call('Input.dispatchKeyEvent', { type: 'keyDown', key: 'ArrowRight', code: 'ArrowRight', windowsVirtualKeyCode: 39 });
  await pause(300);
  await call('Input.dispatchKeyEvent', { type: 'keyUp', key: 'ArrowRight', code: 'ArrowRight', windowsVirtualKeyCode: 39 });
  const keyboardStopped = await screenshot();
  assert.notEqual(keyboardStopped, stopped, 'arrow keyboard movement');
  assert.equal(await screenshot(), keyboardStopped, 'key release stops motion and preserves facing');
  console.log('PASS: stationary direction cycle, held touch, off-pad release, keyboard hold/release');

  for (const [width, height, dpr] of [[360, 640, 1], [640, 360, 1], [480, 800, 1], [390, 844, 2]]) {
    await call('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: dpr, mobile: true });
    await pause(300);
    for (const [index, zoom] of [1, 2, 4, 8].entries()) {
      await tap(32 + index * 52, 80);
      await screenshot(width + 'x' + height + '-dpr' + dpr + '-zoom' + zoom);
    }
    console.log('PASS: browser resize and all scale controls', width, height, 'DPR', dpr);
  }
  assert.deepEqual(errors, [], 'browser runtime errors');
  // One image in logs permits visual review without a game-side dependency.
  await call('Emulation.setDeviceMetricsOverride', { width: 480, height: 800, deviceScaleFactor: 1, mobile: true });
  await pause(300);
  await tap(136, 80);
  console.log('RF_SCREENSHOT_BASE64:' + await screenshot('review', true));
  console.log('PASS: no browser runtime errors. Emulation is not an Android device test.');
} finally {
  socket?.close();
  chrome.kill('SIGTERM');
}
