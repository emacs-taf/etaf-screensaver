#!/usr/bin/env node
// Bake a canvas animation into an image-frame bundle for etaf-screensaver.
//
// Two modes:
//   --preset NAME   render a Butterchurn (MilkDrop) preset through a bundled
//                   harness with virtual time, so baking runs as fast as the
//                   GPU renders and is reproducible
//   --url URL       capture any page's <canvas> in real time (p5 sketches,
//                   shader previews); --canvas selects the element
//
// The bundle holds f%05d.<ext> frames plus a frames.json manifest that
// `etaf-screensaver-import-recording` reads.  Nothing here runs at playback.
//
// Usage:
//   node bake-canvas-frames.mjs --list-presets
//   node bake-canvas-frames.mjs --preset "$$$ Royal - Mashup (197)" \
//     --seconds 10 --fps 24 --width 960 --height 540 --out /tmp/reel
//   node bake-canvas-frames.mjs --url file:///path/sketch.html \
//     --seconds 8 --fps 20 --width 800 --height 450 --out /tmp/reel
//
// Prerequisites for --preset: `npm install butterchurn butterchurn-presets`
// in --modules (default ./node_modules).  A Chrome with remote debugging on
// --cdp-port (default 9222) must be running; the script opens and closes its
// own tab and never touches other tabs.

import { createServer } from 'node:http';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { extname, basename, join, normalize, resolve } from 'node:path';

const DEFAULTS = {
  cdpPort: 9222,
  modules: 'node_modules',
  fps: 24,
  seconds: 10,
  width: 960,
  height: 540,
  format: 'webp',
  quality: 0.75,
  manifest: null,
  canvas: 'canvas',
  warmup: 2,
  audio: 'synthetic',
};

function usage(message) {
  if (message) console.error('error: ' + message);
  console.error(`usage: node bake-canvas-frames.mjs (--preset NAME [--modules DIR] | --url URL [--canvas SEL])
       [--seconds S] [--fps N] [--width W] [--height H] [--warmup S]
       [--out DIR] [--manifest NAME] [--format webp|jpeg|png] [--quality Q]
       [--source TEXT] [--license TEXT] [--cdp-port N] [--list-presets]`);
  process.exit(2);
}

function parseArguments(argv) {
  const options = { ...DEFAULTS, out: null, preset: null, url: null, source: null, license: null, listPresets: false };
  for (let index = 0; index < argv.length; index++) {
    const flag = argv[index];
    const value = () => {
      if (index + 1 >= argv.length) usage(`${flag} needs a value`);
      return argv[++index];
    };
    switch (flag) {
      case '--preset': options.preset = value(); break;
      case '--url': options.url = value(); break;
      case '--canvas': options.canvas = value(); break;
      case '--seconds': options.seconds = Number(value()); break;
      case '--fps': options.fps = Number(value()); break;
      case '--width': options.width = Number(value()); break;
      case '--height': options.height = Number(value()); break;
      case '--warmup': options.warmup = Number(value()); break;
      case '--out': options.out = resolve(value()); break;
      case '--manifest': options.manifest = value(); break;
      case '--format': options.format = value(); break;
      case '--quality': options.quality = Number(value()); break;
      case '--source': options.source = value(); break;
      case '--license': options.license = value(); break;
      case '--cdp-port': options.cdpPort = Number(value()); break;
      case '--audio': options.audio = value(); break;
      case '--modules': options.modules = resolve(value()); break;
      case '--list-presets': options.listPresets = true; break;
      case '--help': usage(); break;
      default: usage(`unknown flag ${flag}`);
    }
  }
  if (options.listPresets) return options;
  if (!options.out) usage('--out is required');
  if (!!options.preset === !!options.url) usage('pass exactly one of --preset or --url');
  if (!(options.seconds > 0) || !(options.fps > 0) || !(options.width > 0) || !(options.height > 0)) {
    usage('--seconds, --fps, --width and --height must be positive');
  }
  if (!['webp', 'jpeg', 'png'].includes(options.format)) usage('--format must be webp, jpeg or png');
  if (!['synthetic', 'silence'].includes(options.audio)) usage('--audio must be synthetic or silence');
  if (!options.manifest) options.manifest = `${basename(options.out)}.frames.json`;
  if (!(options.quality > 0 && options.quality <= 1)) usage('--quality must be in (0, 1]');
  return options;
}

const MIME = { webp: 'image/webp', jpeg: 'image/jpeg', png: 'image/png' };
const QUALITY = { webp: [0.1, 1], jpeg: [0.1, 1], png: [0, 1] };

function butterchurnHarness(options) {
  return `<!doctype html><html><head><meta charset="utf-8">
<style>html,body{margin:0;background:#000}canvas{display:block}</style>
<script>
window.__vt = 0;
performance.now = () => window.__vt;
window.__bake = { ready: false, error: null };
</script>
<script src="/modules/butterchurn/lib/butterchurn.min.js"></script>
<script src="/modules/butterchurn-presets/lib/butterchurnPresets.min.js"></script>
<script>
window.__bake.names = () => Object.keys(butterchurnPresets.getPresets());
window.__bake.start = function (opts) {
  try {
    const canvas = document.createElement('canvas');
    canvas.width = opts.width; canvas.height = opts.height;
    document.body.appendChild(canvas);
    const engine = butterchurn.default || butterchurn;
    const visualizer = engine.createVisualizer(new AudioContext(), canvas,
      { width: opts.width, height: opts.height, pixelRatio: 1 });
    // MilkDrop presets react to spectrum levels; feed a deterministic
    // waveform driven by virtual time so an offline bake is reproducible
    // and presets that need audio do not stay black.
    const audioSize = visualizer.audio.fftSize;
    let seed = 987654321;
    const random = () => {
      seed ^= seed << 13; seed ^= seed >>> 17; seed ^= seed << 5;
      return ((seed >>> 0) % 1024) / 1024;
    };
    const audioLevels = (seconds) => {
      const bass = 0.55 + 0.45 * Math.sin(seconds * Math.PI * 2 * 0.45);
      const mid = 0.5 + 0.5 * Math.sin(seconds * Math.PI * 2 * 1.1 + 1.7);
      const treble = 0.5 + 0.5 * Math.sin(seconds * Math.PI * 2 * 2.3 + 0.4);
      const bytes = new Uint8Array(audioSize);
      for (let index = 0; index < audioSize; index++) {
        const phase = (index / audioSize) * Math.PI * 2;
        const sample = 0.5 * Math.sin(phase * 3) * bass
                     + 0.25 * (random() * 2 - 1) * mid
                     + 0.15 * Math.sin(phase * 40) * treble;
        bytes[index] = Math.max(0, Math.min(255, Math.round(128 + 120 * sample)));
      }
      return { timeByteArray: bytes, timeByteArrayL: bytes, timeByteArrayR: bytes };
    };
    const preset = butterchurnPresets.getPresets()[opts.preset];
    if (!preset) throw new Error('unknown preset: ' + opts.preset);
    visualizer.loadPreset(preset, 0);
    window.__bake.advance = function (milliseconds) {
      window.__vt += milliseconds;
      visualizer.render(opts.audio === 'synthetic'
        ? { audioLevels: audioLevels(window.__vt / 1000), elapsedTime: milliseconds / 1000 }
        : { elapsedTime: milliseconds / 1000 });
    };
    window.__bake.render = function (milliseconds) {
      window.__bake.advance(milliseconds);
      return canvas.toDataURL(opts.mime, opts.quality);
    };
    window.__bake.ready = true;
  } catch (error) { window.__bake.error = String(error && error.stack || error); }
};
</script></head><body></body></html>`;
}

async function serveDirectory(modules, harness) {
  const server = createServer(async (request, response) => {
    const path = decodeURIComponent(new URL(request.url, 'http://localhost').pathname);
    try {
      let body, type;
      if (path === '/harness.html' && harness) {
        body = harness;
        type = 'text/html';
      } else if (path.startsWith('/modules/')) {
        const file = normalize(join(modules, path.slice('/modules/'.length)));
        if (file !== modules && !file.startsWith(modules + '/')) throw new Error('forbidden');
        body = await readFile(file);
        type = { '.js': 'text/javascript' }[extname(file)] || 'application/octet-stream';
      } else {
        throw new Error('not found');
      }
      response.writeHead(200, { 'content-type': type });
      response.end(body);
    } catch (error) {
      response.writeHead(404);
      response.end(String(error));
    }
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  return { server, port: server.address().port };
}

class Cdp {
  constructor(socket) {
    this.socket = socket;
    this.nextId = 1;
    this.pending = new Map();
    socket.onmessage = (event) => {
      const message = JSON.parse(event.data);
      const waiter = message.id && this.pending.get(message.id);
      if (!waiter) return;
      this.pending.delete(message.id);
      if (message.error) waiter.reject(new Error(JSON.stringify(message.error)));
      else waiter.resolve(message.result);
    };
  }
  send(method, params = {}) {
    return new Promise((resolve, reject) => {
      const id = this.nextId++;
      this.pending.set(id, { resolve, reject });
      this.socket.send(JSON.stringify({ id, method, params }));
    });
  }
  async evaluate(expression) {
    const result = await this.send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
    if (result.exceptionDetails) throw new Error(JSON.stringify(result.exceptionDetails));
    return result.result.value;
  }
}

async function connect(port) {
  let targets;
  try {
    targets = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT' })).json();
  } catch (error) {
    throw new Error(`Chrome with remote debugging is not reachable on port ${port} (${error.message})`);
  }
  const socket = new WebSocket(targets.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = () => reject(new Error('CDP socket failed')); });
  const cdp = new Cdp(socket);
  await cdp.send('Runtime.enable');
  await cdp.send('Page.enable');
  return { cdp, socket, target: targets };
}

async function poll(attempts, delayMs, test, description) {
  for (let attempt = 0; attempt < attempts; attempt++) {
    const value = await test();
    if (value) return value;
    await new Promise((resolve) => setTimeout(resolve, delayMs));
  }
  throw new Error(description);
}

async function main() {
  const options = parseArguments(process.argv.slice(2));
  const { cdp, socket, target } = await connect(options.cdpPort);
  let server;
  try {
    if (options.preset || options.listPresets) {
      const butterchurn = join(options.modules, 'butterchurn/lib/butterchurn.min.js');
      const presets = join(options.modules, 'butterchurn-presets/lib/butterchurnPresets.min.js');
      for (const file of [butterchurn, presets]) {
        if (!existsSync(file)) {
          throw new Error(`missing ${file}; run: npm install butterchurn butterchurn-presets --prefix ${options.modules}`);
        }
      }
      const served = await serveDirectory(options.modules, butterchurnHarness(options));
      server = served.server;
      await cdp.send('Page.navigate', { url: `http://127.0.0.1:${served.port}/harness.html` });
      await poll(200, 50, () => cdp.evaluate('typeof window.__bake === "object" && typeof butterchurnPresets === "function"'),
                 'harness page never loaded');
      const names = await cdp.evaluate('__bake.names()');
      if (options.listPresets) {
        console.log(names.join('\n'));
        return;
      }
      if (options.format === 'webp') {
        const probe = await cdp.evaluate(
          "document.createElement('canvas').toDataURL('image/webp').slice(0, 15)");
        if (probe !== 'data:image/webp') {
          console.error('note: this browser cannot encode webp from a canvas; using jpeg');
          options.format = 'jpeg';
        }
      }
      options.mime = MIME[options.format];
      await cdp.evaluate(`__bake.start(${JSON.stringify({ width: options.width, height: options.height, preset: options.preset, mime: options.mime, quality: options.quality, audio: options.audio })})`);
      await poll(200, 50, () => cdp.evaluate('__bake.error || (__bake.ready ? "ready" : "")'),
                 'butterchurn never became ready');
      if (options.warmup > 0) {
        await cdp.evaluate(`__bake.advance(${options.warmup * 1000})`);
      }
    } else {
      await cdp.send('Emulation.setDeviceMetricsOverride',
                     { width: options.width, height: options.height, deviceScaleFactor: 1, mobile: false });
      await cdp.send('Page.navigate', { url: options.url });
      await poll(200, 100, () => cdp.evaluate(`!!document.querySelector(${JSON.stringify(options.canvas)})`),
                 `canvas ${options.canvas} never appeared`);
      if (options.warmup > 0) await new Promise((resolve) => setTimeout(resolve, options.warmup * 1000));
    }

    await mkdir(options.out, { recursive: true });
    const frames = Math.max(1, Math.round(options.seconds * options.fps));
    const extension = options.format === 'jpeg' ? 'jpg' : options.format;
    const quality = options.quality;
    const names = [];
    const started = Date.now();
    for (let frame = 0; frame < frames; frame++) {
      const data = options.preset
        ? await cdp.evaluate(`__bake.render(${1000 / options.fps})`)
        : await cdp.evaluate(`document.querySelector(${JSON.stringify(options.canvas)}).toDataURL(${JSON.stringify(MIME[options.format])}, ${quality})`);
      const base64 = data.slice(data.indexOf(',') + 1);
      const name = `f${String(frame).padStart(5, '0')}.${extension}`;
      await writeFile(join(options.out, name), Buffer.from(base64, 'base64'));
      names.push(name);
      if (!options.preset) {
        const targetTime = started + ((frame + 1) * 1000) / options.fps;
        const wait = targetTime - Date.now();
        if (wait > 0) await new Promise((resolve) => setTimeout(resolve, wait));
      }
      if ((frame + 1) % options.fps === 0) process.stderr.write(`\r${frame + 1}/${frames}`);
    }
    process.stderr.write('\n');
    const manifest = {
      version: 1,
      width: options.width,
      height: options.height,
      frame_rate: options.fps,
      frames: names,
      ...(options.source ? { source: options.source } : {}),
      ...(options.license ? { license: options.license } : {}),
    };
    await writeFile(join(options.out, options.manifest), JSON.stringify(manifest, null, 1) + '\n');
    console.log(`baked ${frames} frames to ${options.out} (${options.width}x${options.height} at ${options.fps} fps)`);
  } finally {
    try { await fetch(`http://127.0.0.1:${options.cdpPort}/json/close/${target.id}`); } catch { /* tab is gone */ }
    socket.close();
    if (server) server.close();
  }
}

main().catch((error) => {
  console.error('bake failed: ' + error.message);
  process.exitCode = 1;
});
