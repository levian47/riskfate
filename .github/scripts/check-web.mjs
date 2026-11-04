// Browser verification only; no npm packages or game-side JavaScript.
import { spawn } from 'node:child_process';
import { mkdir, writeFile, readFile } from 'node:fs/promises';
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
    const result = await call('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
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
  async function metrics(width, height, dpr, mobile = true) {
    await call('Emulation.setDeviceMetricsOverride', {
      width, height, deviceScaleFactor: dpr, mobile,
      screenOrientation: width > height
        ? { type: 'landscapePrimary', angle: 90 } : { type: 'portraitPrimary', angle: 0 }
    });
  }
  async function loadGame(touch) {
    await call('Emulation.setTouchEmulationEnabled', { enabled: touch });
    await metrics(480, 800, 1, touch);
    const previousOrigin = await evaluate('performance.timeOrigin');
    await call('Page.navigate', { url });
    let started = false;
    for (let attempt = 0; attempt < 120; attempt++) {
      try {
        started = await evaluate(
          'performance.timeOrigin !== ' + previousOrigin +
          " && !!document.getElementById('canvas') && !document.getElementById('status')"
        );
      } catch { /* Navigation can replace the JavaScript context during this poll. */ }
      if (started || errors.length) break;
      await pause(500);
    }
    assert(started, 'Godot did not finish loading: ' + errors.join('\n'));
    assert.equal(await evaluate('GODOT_THREADS_ENABLED'), false, 'single-thread Web build');
    await pause(500);
  }
  // Decode test screenshots using browser APIs; no game hooks or image packages.
  async function inspectImage(shot, frame = null, point = null) {
    const inspect = async ({ shot, frame, point }) => {
      async function pixels(encoded) {
        const bitmap = await createImageBitmap(await (await fetch('data:image/png;base64,' + encoded)).blob());
        const canvas = new OffscreenCanvas(bitmap.width, bitmap.height);
        const context = canvas.getContext('2d');
        context.drawImage(bitmap, 0, 0);
        const data = context.getImageData(0, 0, bitmap.width, bitmap.height);
        bitmap.close();
        return data;
      }
      const screen = await pixels(shot);
      if (point) {
        const index = (point[1] * screen.width + point[0]) * 4;
        return Array.from(screen.data.slice(index, index + 3));
      }
      const source = await pixels(frame);
      let best = 0;
      // Portrait 480x800, native DPR 1, zoom 4. Allow camera pixel snapping.
      for (let oy = 240; oy <= 246; oy++) {
        for (let ox = 141; ox <= 147; ox++) {
          let hits = 0;
          let total = 0;
          for (let y = 0; y < source.height; y++) {
            for (let x = 0; x < source.width; x++) {
              const src = (y * source.width + x) * 4;
              if (source.data[src + 3] !== 255) continue;
              const dst = ((oy + y * 4 + 2) * screen.width + ox + x * 4 + 2) * 4;
              total++;
              if (screen.data[dst] === source.data[src] &&
                  screen.data[dst + 1] === source.data[src + 1] &&
                  screen.data[dst + 2] === source.data[src + 2]) hits++;
            }
          }
          best = Math.max(best, hits / total);
          if (best === 1) return best;
        }
      }
      return best;
    };
    return evaluate('(' + inspect.toString() + ')(' + JSON.stringify({ shot, frame, point }) + ')');
  }
  async function assertKnob(visible, width = 480, height = 800, dpr = 1) {
    const color = await inspectImage(await screenshot(null, true), null, [84 * dpr, (height - 84) * dpr]);
    assert.equal(color.every(channel => channel > 100), visible,
      'joystick center visibility at ' + width + 'x' + height + ' DPR ' + dpr);
  }
  async function touch(type, x, y) {
    await call('Input.dispatchTouchEvent', {
      type, touchPoints: type === 'touchEnd' || type === 'touchCancel' ? [] : [{ x, y }]
    });
    await pause(200);
  }
  async function assertStopped(description) {
    const stopped = await screenshot();
    assert.equal(await screenshot(), stopped, description);
  }
  await call('Page.enable');
  await call('Runtime.enable');
  await loadGame(false);
  assert.equal(await evaluate("'ontouchstart' in window"), false, 'desktop touch capability disabled');
  await assertKnob(false);
  const desktopInitial = await screenshot('desktop-no-joystick');
  for (const [key, code, virtualKey] of [['ArrowRight', 'ArrowRight', 39], ['w', 'KeyW', 87]]) {
    await call('Input.dispatchKeyEvent', { type: 'keyDown', key, code, windowsVirtualKeyCode: virtualKey });
    await pause(300);
    await call('Input.dispatchKeyEvent', { type: 'keyUp', key, code, windowsVirtualKeyCode: virtualKey });
    assert.notEqual(await screenshot(), desktopInitial, 'desktop keyboard movement: ' + code);
    await assertStopped('desktop key release stops movement');
  }
  console.log('PASS: Web desktop hides joystick; arrow and WASD controls work');

  await loadGame(true);
  assert.equal(await evaluate("'ontouchstart' in window"), true, 'mobile touch capability enabled');
  await assertKnob(true);
  console.log('PASS: Godot Web shows joystick only with touchscreen capability');
  // At DPR 1 the world and UI use native canvas pixels. Cycle directions at rest.
  const initial = await screenshot('initial');
  await tap(256, 80);
  assert.notEqual(await screenshot(), initial, 'stationary direction button changes frame');
  for (let index = 0; index < 7; index++) await tap(256, 80);
  assert.equal(await screenshot('cycled'), initial, 'eight stationary turns return to original frame');

  // Hold the same finger while changing angle. Rendered hero pixels must match
  // the approved PNG for the nearest of eight views, including off-axis cases.
  await touch('touchStart', 84, 716);
  await assertStopped('joystick dead zone has no movement');
  for (const [degrees, facing] of [
    [0, 'E'], [10, 'E'], [-10, 'E'], [-25, 'NE'], [-45, 'NE'],
    [-80, 'N'], [-135, 'NW'], [180, 'W'], [135, 'SW'], [90, 'S'], [45, 'SE']
  ]) {
    const radians = degrees * Math.PI / 180;
    await touch('touchMove', 84 + 54 * Math.cos(radians), 716 + 54 * Math.sin(radians));
    const png = await readFile('assets_source/character_sprites/base_hero_v1/riskfate_hero_' + facing + '_48x64.png');
    assert.equal(await inspectImage(await screenshot('joystick-' + degrees, true), png.toString('base64')), 1,
      'rendered joystick facing ' + facing + ' at ' + degrees + ' degrees');
  }
  await touch('touchMove', 250, 600);
  await touch('touchEnd');
  await assertStopped('release outside joystick stops motion');
  await assertKnob(true);

  await touch('touchStart', 138, 716);
  await touch('touchCancel');
  await assertStopped('browser touch cancellation stops motion');
  await assertKnob(true);

  await touch('touchStart', 138, 716);
  await evaluate("document.getElementById('canvas').blur()");
  assert.equal(await evaluate("document.activeElement === document.getElementById('canvas')"), false);
  await assertStopped('browser canvas focus loss stops joystick');
  await evaluate("document.getElementById('canvas').focus()");
  await touch('touchMove', 138, 716);
  await assertStopped('old finger cannot resume after focus returns');
  await touch('touchEnd');

  await touch('touchStart', 138, 716);
  await metrics(800, 480, 1);
  await pause(500);
  await assertStopped('rotation stops held joystick');
  await touch('touchMove', 138, 396);
  await assertStopped('old finger cannot resume after rotation');
  await touch('touchEnd');
  await assertKnob(true, 800, 480);
  const afterRotation = await screenshot();
  await touch('touchStart', 138, 396);
  assert.notEqual(await screenshot(), afterRotation, 'new touch works after rotation');
  await touch('touchEnd');
  await assertStopped('release after rotation stops joystick');
  console.log('PASS: eight rendered views, arbitrary angles, dead zone, outside release, cancellation, focus loss and rotation');
  for (const [width, height, dpr] of [[360, 640, 1], [640, 360, 1], [480, 800, 1], [390, 844, 2]]) {
    await metrics(width, height, dpr);
    await pause(300);
    for (const [index, zoom] of [1, 2, 4, 8].entries()) {
      await tap(32 + index * 52, 80);
      await screenshot(width + 'x' + height + '-dpr' + dpr + '-zoom' + zoom);
    }
    await assertKnob(true, width, height, dpr);
    const beforeDrag = await screenshot();
    await touch('touchStart', 124, height - 84);
    assert.notEqual(await screenshot(), beforeDrag, 'joystick works after resize at DPR ' + dpr);
    await touch('touchEnd');
    await assertStopped('joystick release at DPR ' + dpr);
    console.log('PASS: browser resize, joystick and scale controls', width, height, 'DPR', dpr);
  }
  assert.deepEqual(errors, [], 'browser runtime errors');
  // One image in logs permits visual review without a game-side dependency.
  await metrics(480, 800, 1);
  await pause(300);
  await tap(136, 80);
  console.log('RF_SCREENSHOT_BASE64:' + await screenshot('review', true));
  console.log('PASS: no browser runtime errors. Emulation is not an Android device test.');
} finally {
  socket?.close();
  chrome.kill('SIGTERM');
}
