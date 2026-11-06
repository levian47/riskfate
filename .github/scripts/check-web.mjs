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
      const error = message.params.args.map(value => value.value ?? value.description).join(' ');
      errors.push(error);
      console.error('Godot Web:', error);
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
    assert.deepEqual(errors, [], 'Godot Web startup errors');
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
  async function click(x, y) {
    await call('Input.dispatchMouseEvent', { type: 'mousePressed', x, y, button: 'left', clickCount: 1 });
    await call('Input.dispatchMouseEvent', { type: 'mouseReleased', x, y, button: 'left', clickCount: 1 });
    await call('Input.dispatchMouseEvent', { type: 'mouseMoved', x: 0, y: 0 });
    await pause(400);
  }
  async function holdKey(key, code, virtualKey, ms) {
    await call('Input.dispatchKeyEvent', { type: 'keyDown', key, code, windowsVirtualKeyCode: virtualKey });
    await pause(ms);
    await call('Input.dispatchKeyEvent', { type: 'keyUp', key, code, windowsVirtualKeyCode: virtualKey });
    await pause(150);
  }
  // Compare actual Web pixels with existing PNGs, including nearest scaling.
  // Clipped edges are ignored; opaque source pixels must otherwise match exactly.
  async function spriteMatch(shot, file, origin, scale = 1, region = null) {
    const source = (await readFile(file)).toString('base64');
    const compare = async ({ shot, source, origin, scale, region }) => {
      async function decode(encoded) {
        const bitmap = await createImageBitmap(await (await fetch('data:image/png;base64,' + encoded)).blob());
        const context = new OffscreenCanvas(bitmap.width, bitmap.height).getContext('2d');
        context.drawImage(bitmap, 0, 0);
        return context.getImageData(0, 0, bitmap.width, bitmap.height);
      }
      const screen = await decode(shot), png = await decode(source);
      const [rx, ry, rw, rh] = region ?? [0, 0, png.width, png.height];
      let best = 0;
      for (let dy = -3; dy <= 3; dy++) for (let dx = -3; dx <= 3; dx++) {
        let hits = 0, total = 0;
        for (let y = 0; y < rh; y++) for (let x = 0; x < rw; x++) {
          const src = ((ry + y) * png.width + rx + x) * 4;
          const sx = origin[0] + dx + x * scale, sy = origin[1] + dy + y * scale;
          if (png.data[src + 3] !== 255 || sx < 6 || sx + scale > screen.width - 6 || sy < 110 || sy + scale > 632) continue;
          for (let py = 0; py < scale; py++) for (let px = 0; px < scale; px++) {
            const dst = ((sy + py) * screen.width + sx + px) * 4;
            total++;
            if (screen.data[dst] === png.data[src] && screen.data[dst + 1] === png.data[src + 1] &&
                screen.data[dst + 2] === png.data[src + 2]) hits++;
          }
        }
        if (total > 64) best = Math.max(best, hits / total);
      }
      return best;
    };
    return evaluate('(' + compare.toString() + ')(' + JSON.stringify({ shot, source, origin, scale, region }) + ')');
  }
  await call('Page.enable');
  await call('Runtime.enable');
  await loadGame(false);
  // The new main scene must work on desktop before entering the original lab.
  await metrics(1280, 720, 1, false);
  await pause(400);
  console.log('RF_SETTLEMENT_DESKTOP_BASE64:' + await screenshot('settlement-desktop', true));
  await holdKey('ArrowRight', 'ArrowRight', 39, 300);
  await assertStopped('settlement desktop key release stops physics');
  await metrics(480, 800, 1, false);
  await pause(400);
  await click(410, 20); // Settlement -> original hero laboratory.
  assert.equal(await evaluate("'ontouchstart' in window"), false, 'desktop touch capability disabled');
  await assertKnob(false);
  await screenshot('desktop-no-joystick');
  for (const [key, code, virtualKey] of [['ArrowRight', 'ArrowRight', 39], ['w', 'KeyW', 87]]) {
    const desktopInitial = await screenshot();
    await call('Input.dispatchKeyEvent', { type: 'keyDown', key, code, windowsVirtualKeyCode: virtualKey });
    await pause(300);
    await call('Input.dispatchKeyEvent', { type: 'keyUp', key, code, windowsVirtualKeyCode: virtualKey });
    assert.notEqual(await screenshot(), desktopInitial, 'desktop keyboard movement: ' + code);
    await assertStopped('desktop key release stops movement');
  }
  console.log('PASS: Web desktop hides joystick; arrow and WASD controls work');

  await loadGame(true);
  await assertKnob(true);
  const settlement = await screenshot('settlement-portrait', true);
  console.log('RF_SETTLEMENT_MOBILE_BASE64:' + settlement);
  for (const [file, origin, region] of [
    ['world/environment/settlement_v1/tree_large_v2.png', [-2, 352]],
    ['world/environment/settlement_v1/well.png', [304, 219]],
    ['world/environment/settlement_v1/fence_horizontal.png', [-20, 513]],
    ['world/tilesets/settlement_v1/grass_32.png', [304, 177]],
    ['world/tilesets/settlement_v1/dirt_32.png', [176, 401]],
    ['world/tilesets/settlement_v1/dirt_grass_47_atlas.png', [208, 113], [128, 32, 32, 32]]
  ]) {
    assert.equal(await spriteMatch(settlement, file, origin, 1, region), 1, 'settlement rendered original pixels: ' + file);
  }
  // At spawn the nearby western tree is safely reachable above its root.
  // The camera follows the feet; the hero stays at the same screen coordinates.
  const heroAtlas = 'characters/player/base_hero/hero_8dir.png';
  for (const [index, zoom] of [1, 2, 4, 8].entries()) {
    await tap(32 + index * 52, 80);
    const shot = await screenshot('settlement-pixels-zoom' + zoom, true);
    assert.equal(await spriteMatch(shot, heroAtlas, [240 - 24 * zoom, 371 - 32 * zoom],
      zoom, [0, 0, 48, 64]), 1, 'settlement hero exact nearest pixel blocks at zoom ' + zoom);
    if (zoom === 2) assert.equal(await spriteMatch(shot, 'world/environment/settlement_v1/well.png',
      [368, 67], 2), 1, 'settlement well exact 2x pixel blocks');
  }
  await tap(32, 80);
  await holdKey('ArrowLeft', 'ArrowLeft', 37, 1900);
  assert(await spriteMatch(await screenshot('settlement-behind-tree', true), heroAtlas,
    [216, 339], 1, [6 * 48, 0, 48, 64]) < 0.6, 'tree canopy occludes hero behind it');
  await holdKey('ArrowRight', 'ArrowRight', 39, 700);
  await holdKey('ArrowDown', 'ArrowDown', 40, 900);
  await holdKey('ArrowLeft', 'ArrowLeft', 37, 700);
  const frontTree = await screenshot('settlement-front-tree', true);
  const treeFrontMatch = await spriteMatch(frontTree, heroAtlas, [216, 339], 1, [6 * 48, 0, 48, 64]);
  if (treeFrontMatch !== 1) console.log('RF_FAILURE_BASE64:' + frontTree);
  assert.equal(treeFrontMatch, 1, 'hero renders in front of tree after walking around root');
  await assertStopped('settlement physics stops after release');
  await loadGame(true);
  // Use the gate to approach the same horizontal fence from each side.
  await holdKey('ArrowDown', 'ArrowDown', 40, 1800);
  await holdKey('ArrowLeft', 'ArrowLeft', 37, 1160);
  await holdKey('ArrowUp', 'ArrowUp', 38, 1000);
  const frontFence = await screenshot('settlement-front-fence', true);
  const fenceFrontMatch = await spriteMatch(frontFence, heroAtlas, [216, 339], 1, [4 * 48, 0, 48, 64]);
  if (fenceFrontMatch !== 1) console.log('RF_FAILURE_BASE64:' + frontFence);
  assert.equal(fenceFrontMatch, 1, 'hero renders in front of fence at collision stop');
  await holdKey('ArrowRight', 'ArrowRight', 39, 1160);
  await holdKey('ArrowUp', 'ArrowUp', 38, 1000);
  await holdKey('ArrowLeft', 'ArrowLeft', 37, 1160);
  await holdKey('ArrowDown', 'ArrowDown', 40, 2000);
  assert(await spriteMatch(await screenshot('settlement-behind-fence', true), heroAtlas,
    [216, 339], 1, [0, 0, 48, 64]) < 0.99, 'fence occludes lower hero pixels from behind');
  // Reload for a repeatable mobile input/rotation/scale matrix in the real location.
  await loadGame(true);
  for (const [width, height, dpr] of [[480, 800, 1], [800, 480, 1], [390, 844, 2]]) {
    await metrics(width, height, dpr);
    await pause(400);
    for (const [index, zoom] of [1, 2, 4, 8].entries()) {
      await tap(32 + index * 52, 80);
      await screenshot('settlement-' + width + 'x' + height + '-dpr' + dpr + '-zoom' + zoom);
    }
    await assertKnob(true, width, height, dpr);
    const before = await screenshot();
    await touch('touchStart', 124, height - 84);
    await touch('touchEnd');
    assert.notEqual(await screenshot(), before, 'settlement joystick moves player at DPR ' + dpr);
    await assertStopped('settlement joystick release after resize');
  }
  await loadGame(true);
  await touch('touchStart', 138, 716);
  await metrics(800, 480, 1);
  await pause(400);
  await assertStopped('settlement rotation clears held input');
  await touch('touchEnd');
  await touch('touchStart', 138, 396);
  await evaluate("document.getElementById('canvas').blur()");
  await assertStopped('settlement focus loss stops physics player');
  await touch('touchEnd');
  await loadGame(true);
  await tap(410, 20); // Settlement -> original laboratory regression tests below.
  console.log('PASS: settlement original terrain/prop pixels, tree occlusion, desktop/mobile physics, zooms, rotation and focus');
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
