// Headless Edge over CDP: load AcidFlow.html, wait on simulation time, screenshot.
// usage: node Test-AcidFlow.mjs <url> <outdir> <plan>   plan = "label@simT[:urlencoded js]" comma separated
// example (from this folder): node src/Test-AcidFlow.mjs "file:///$PWD/AcidFlow.html?hint=0&fps=60&scale=0.5" out "seed@2:window.__acidSpawnBubble(),grown@8"
// Needs Node 22+ (global fetch and WebSocket) and Microsoft Edge; adjust the edge path below for another Chromium.
// Swiftshader runs several times slower than real time: the plan waits on simulation time, not wall time.
import { spawn } from 'node:child_process';
import { writeFileSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const [,, url, outDir, planText] = process.argv;
mkdirSync(outDir, { recursive: true });
const port = 9333 + Math.floor(Math.random() * 500);
const profile = join(tmpdir(), 'acid-edge-' + port);
const edge = 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
const proc = spawn(edge, [
  '--headless=new', '--remote-debugging-port=' + port, '--window-size=1280,720',
  '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist',
  '--no-first-run', '--no-default-browser-check', '--user-data-dir=' + profile,
  '--allow-file-access-from-files', '--disable-sync', url,
], { stdio: 'ignore' });
const sleep = ms => new Promise(r => setTimeout(r, ms));
let target = null;
for (let i = 0; i < 60 && !target; i++) {
  await sleep(500);
  try { const list = await (await fetch(`http://127.0.0.1:${port}/json`)).json(); target = list.find(t => t.type === 'page' && /AcidFlow/.test(t.url)); } catch {}
}
if (!target) { proc.kill(); throw new Error('no page target'); }
console.log('target', target.url);
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
let id = 0; const pending = new Map();
const logs = [];
ws.onmessage = ev => {
  const m = JSON.parse(ev.data);
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); }
  else if (m.method === 'Runtime.consoleAPICalled') logs.push(m.params.type + ': ' + m.params.args.map(a => a.value ?? a.description).join(' '));
  else if (m.method === 'Runtime.exceptionThrown') logs.push('EXCEPTION: ' + (m.params.exceptionDetails.exception?.description || m.params.exceptionDetails.text));
  else if (m.method === 'Log.entryAdded') logs.push('log.' + m.params.entry.level + ': ' + m.params.entry.text);
};
const send = (method, params = {}) => new Promise(res => { const i = ++id; pending.set(i, res); ws.send(JSON.stringify({ id: i, method, params })); });
const evalJs = async expr => { const r = await send('Runtime.evaluate', { expression: expr, returnByValue: true }); return r.result?.result?.value; };
await send('Runtime.enable'); await send('Log.enable'); await send('Page.enable');
await send('Emulation.setDeviceMetricsOverride', { width: 1280, height: 720, deviceScaleFactor: 1, mobile: false });
for (let i = 0; i < 60; i++) { if (await evalJs('!!window.__acid')) break; await sleep(500); }
const errShown = await evalJs("getComputedStyle(document.getElementById('err')).display");
console.log('err display:', errShown, 'simTime:', await evalJs('window.__acid.simTime'));
const plan = planText.split(',').map(s => { const [label, rest] = s.split('@'); const sep = rest.indexOf(':'); const t = sep < 0 ? rest : rest.slice(0, sep), js = sep < 0 ? undefined : rest.slice(sep + 1); return { label, t: parseFloat(t), js }; });
const t0 = Date.now();
for (const p of plan) {
  while (true) {
    const st = await evalJs('window.__acid.simTime');
    if (st >= p.t) break;
    if (Date.now() - t0 > 600000) throw new Error('timeout waiting for simTime ' + p.t);
    await sleep(200);
  }
  if (p.js) await evalJs(decodeURIComponent(p.js));
  const st = await evalJs('window.__acid.simTime');
  const info = await evalJs('JSON.stringify({bub: window.__acidBubbles ? window.__acidBubbles.length : null, fps: window.__acid.fpsCap, scale: window.__acid.renderScale})');
  const shot = await send('Page.captureScreenshot', { format: 'png' });
  writeFileSync(join(outDir, p.label + '.png'), Buffer.from(shot.result.data, 'base64'));
  console.log(`shot ${p.label} at sim ${st.toFixed(1)} wall ${((Date.now() - t0) / 1000).toFixed(0)}s ${info}`);
}
console.log('console:', logs.length ? '\n' + logs.join('\n') : '(empty)');
ws.close(); proc.kill();
process.exit(0);
