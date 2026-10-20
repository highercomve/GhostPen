const assert = require('node:assert/strict');
const { test, before, beforeEach, afterEach, after } = require('node:test');
const { mkdtempSync, rmSync } = require('node:fs');
const { tmpdir } = require('node:os');
const path = require('node:path');
const { build } = require('esbuild');
const { JSDOM } = require('jsdom');

const dom = new JSDOM('<!doctype html><html><body></body></html>', { url: 'http://localhost/summary-test' });
for (const key of ['window', 'document', 'navigator', 'HTMLElement', 'Element', 'Node', 'Event', 'MouseEvent', 'localStorage']) {
  Object.defineProperty(globalThis, key, { configurable: true, value: dom.window[key] });
}
globalThis.IS_REACT_ACT_ENVIRONMENT = true;
const React = require('react');
const { createRoot } = require('react-dom/client');
const { getQueriesForElement, fireEvent: domFireEvent } = require('@testing-library/dom');
const { act } = React;
const screen = getQueriesForElement(document.body);
const directory = mkdtempSync(path.join(tmpdir(), 'ghostpen-summary-test-'));
let Summary, root;

before(async () => {
  const outfile = path.join(directory, 'Summary.cjs');
  await build({
    entryPoints: [path.join(__dirname, '../src/Summary.tsx')], outfile,
    bundle: true, platform: 'node', format: 'cjs', jsx: 'automatic',
    plugins: [{
      name: 'native-bridge',
      setup(b) {
        // Tests run in a fresh checkout without generated Oriel bindings.
        // Only the native shell is mocked; Summary, api and events are real.
        b.onResolve({ filter: /^\.\/oriel$/ }, () => ({ path: 'oriel', namespace: 'test' }));
        b.onLoad({ filter: /.*/, namespace: 'test' }, () => ({ contents: 'export const orielWindow = {}; export const openExternal = (url) => window.oriel.openExternal(url);' }));
        b.onResolve({ filter: /^react(?:\/.*)?$/ }, ({ path: specifier }) => ({ path: require.resolve(specifier), external: true }));
      },
    }],
  });
  Summary = require(outfile).default;
});

let listeners, calls, snapshot, getSnapshot, resolveRun;
const empty = { state: '', title: '', chars: 0, message: '', markdown: '', thinking: '', thinking_requested: false, revision: 0 };
const answer = '## Key points\n\nThe article explains renewable energy.';
const thoughts = 'Analyze the request. Private reasoning without a heading.';

beforeEach(() => {
  localStorage.clear();
  listeners = new Map();
  calls = [];
  snapshot = { ...empty };
  getSnapshot = () => ({ ...snapshot });
  resolveRun = undefined;
  window.oriel = {
    listen(name, callback) {
      if (!listeners.has(name)) listeners.set(name, new Set());
      listeners.get(name).add(callback);
      return () => listeners.get(name).delete(callback);
    },
    async invoke(name, args) {
      calls.push({ name, args });
      if (name === 'summary_state') return getSnapshot();
      if (name === 'clipboard_text') return 'https://example.com/article';
      if (name === 'summarize_link') {
        snapshot.thinking_requested = args.thinking;
        emitStatus('fetching');
        return new Promise((resolve) => { resolveRun = resolve; });
      }
      if (name === 'cancel_ai') {
        emitStatus('error', 'Cancelled.');
        resolveRun?.();
      }
      return null;
    },
    async openExternal(url) { calls.push({ name: 'open_external', args: { url } }); },
  };
});

async function unmount() {
  if (root) await act(async () => root.unmount());
  root = null;
  document.body.replaceChildren();
}
afterEach(unmount);
after(() => { dom.window.close(); rmSync(directory, { recursive: true, force: true }); });

const tick = () => act(async () => { await new Promise((resolve) => setTimeout(resolve, 110)); });
async function mount() {
  const node = document.createElement('div');
  document.body.append(node);
  root = createRoot(node);
  await act(async () => root.render(React.createElement(React.StrictMode, null, React.createElement(Summary))));
  await tick();
}
function dispatch(name, payload) {
  for (const listener of listeners.get(name) ?? []) listener(payload);
}
function emitStatus(state, message = '') {
  snapshot = { ...snapshot, state, message, revision: snapshot.revision + 1 };
  if (state === 'fetching') snapshot = { ...snapshot, markdown: '', thinking: '' };
  dispatch('ghostpen://summary-status', { ...snapshot });
}
function emitDelta(channel, text) {
  const key = channel === 'answer' ? 'markdown' : 'thinking';
  snapshot = { ...snapshot, [key]: snapshot[key] + text, revision: snapshot.revision + 1 };
  dispatch('ghostpen://summary-chunk', { channel, text, revision: snapshot.revision });
}
async function status(value) { act(() => emitStatus(value)); await tick(); }
async function delta(channel, text) { act(() => emitDelta(channel, text)); await tick(); }
async function click(element) { await act(async () => domFireEvent.click(element)); await tick(); }
const toggle = () => screen.getByRole('switch', { name: 'Show thinking' });
const paper = () => document.querySelector('.summary-paper article');
const copy = () => screen.getByRole('button', { name: /^(Copy|Copied)$/ });
const read = () => screen.getByRole('button', { name: /Read summary/ });

test('heading-free thinking never appears in the summary or enables Copy/TTS, including cancellation', async () => {
  await mount();
  await status('writing');
  for (const part of ['Analyze ', 'the request. ', 'Private reasoning without a heading.']) {
    await delta('thinking', part);
    assert.equal(paper(), null);
    assert.equal(document.body.textContent.includes('Analyze'), false);
    assert.equal(copy().disabled, true);
    assert.equal(read().disabled, true);
  }
  await click(screen.getByRole('button', { name: 'Stop', exact: true }));
  assert.equal(copy().disabled, true);
  assert.equal(read().disabled, true);
  assert.equal(paper(), null);
  assert.ok(calls.some((c) => c.name === 'cancel_ai'));
  assert.equal(calls.some((c) => ['copy_text', 'tts_speak'].includes(c.name)), false);
});

test('toolbar switch is a focusable native checkbox, persists, and Reset restores hidden thinking', async () => {
  snapshot = { ...empty, state: 'ready', markdown: answer, thinking: thoughts, revision: 4 };
  await mount();
  assert.equal(toggle().type, 'checkbox');
  assert.equal(toggle().checked, false);
  toggle().focus();
  assert.equal(document.activeElement, toggle());
  const body = screen.getByRole('main');
  body.scrollTop = 600;
  await click(screen.getByText('Show thinking'));
  assert.equal(body.scrollTop, 0, 'Revealed thinking must not remain above the visible answer');
  assert.equal(screen.getByRole('switch', { name: 'Show thinking', checked: true }), toggle());
  assert.equal(toggle().checked, true);
  assert.match(screen.getByRole('region', { name: 'Model thinking' }).textContent, /Analyze the request/);
  await unmount();
  await mount();
  assert.equal(toggle().checked, true);
  assert.equal(paper().textContent.includes(thoughts), false);
  await click(screen.getByRole('button', { name: 'Reset', hidden: true }));
  assert.equal(toggle().checked, false);
  assert.equal(screen.queryByRole('region', { name: 'Model thinking' }), null);
  assert.equal(JSON.parse(localStorage.getItem('ghostpen-summary-reader')).showThinking, false);
});

test('thinking becomes visible during a continuous stream without waiting for a pause', async () => {
  await mount();
  await status('writing');
  await click(toggle());
  for (let i = 0; i < 20; i++) {
    act(() => emitDelta('thinking', `Step ${i}. `));
    await act(async () => { await new Promise((resolve) => setTimeout(resolve, 20)); });
  }
  const region = screen.queryByRole('region', { name: 'Model thinking' });
  assert.ok(region?.textContent.includes('Step 0.'), 'Thinking must render before the stream pauses');
  assert.equal(copy().disabled, true);
  assert.equal(read().disabled, true);
  await status('ready');
  assert.match(screen.getByRole('region', { name: 'Model thinking' }).textContent, /Step 19/);
});

test('an enabled switch explains when a completed response has no thinking', async () => {
  snapshot = { ...empty, state: 'ready', markdown: answer, revision: 1 };
  await mount();
  await click(toggle());
  assert.match(screen.getByRole('region', { name: 'Model thinking' }).textContent, /Thinking wasn't requested.*Summarize again/);
  assert.equal(calls.some((c) => c.name === 'summarize_link'), false, 'Showing an old result must not silently regenerate it');
  await click(copy());
  await click(read());
  assert.deepEqual(calls.filter((c) => ['copy_text', 'tts_speak'].includes(c.name)).map((c) => c.args.text), [answer, answer]);
});

test('the switch requests thinking on the next run and can hide/reveal it after completion', async () => {
  await mount();
  const run = () => screen.getByRole('button', { name: 'Summarize', exact: true });
  await click(run());
  assert.deepEqual(calls.find((c) => c.name === 'summarize_link').args, {
    url: 'https://example.com/article', level: 'standard', thinking: false,
  });
  await click(toggle());
  assert.match(screen.getByRole('region', { name: 'Model thinking' }).textContent, /Thinking wasn't requested/);
  assert.equal(calls.filter((c) => c.name === 'summarize_link').length, 1);
  await act(async () => { emitStatus('ready'); resolveRun(); });
  await tick();
  await click(run());
  assert.equal(calls.filter((c) => c.name === 'summarize_link').at(-1).args.thinking, true);
  assert.match(screen.getByRole('region', { name: 'Model thinking' }).textContent, /Waiting for the model/);
  await delta('thinking', thoughts);
  await delta('answer', answer);
  await act(async () => { emitStatus('ready'); resolveRun(); });
  await tick();
  await click(toggle());
  assert.equal(screen.queryByRole('region', { name: 'Model thinking' }), null);
  await click(toggle());
  assert.match(screen.getByRole('region', { name: 'Model thinking' }).textContent, /Private reasoning/);
  await click(copy());
  await click(read());
  assert.deepEqual(calls.filter((c) => ['copy_text', 'tts_speak'].includes(c.name)).map((c) => c.args.text), [answer, answer]);
  await unmount();
  await mount();
  assert.equal(toggle().checked, true);
  assert.match(screen.getByRole('region', { name: 'Model thinking' }).textContent, /Private reasoning/);
  await click(run());
  assert.equal(calls.filter((c) => c.name === 'summarize_link').at(-1).args.thinking, true, 'Saved preference must apply to requests');
  assert.equal(document.body.textContent.includes(thoughts), false, 'A new run must not render stale thinking');
  await click(toggle());
  await act(async () => { emitStatus('ready'); resolveRun(); });
  await click(run());
  assert.equal(calls.filter((c) => c.name === 'summarize_link').at(-1).args.thinking, false);
  await act(async () => resolveRun());
});

test('a new thinking-off summary renders the live Key points and Details as sections, not list text', async () => {
  const fixture = require('../../src/fixtures/summary-gemma4-e4b.json');
  const generated = fixture.formatted_output.chunks.join('');
  await mount();
  await click(screen.getByRole('button', { name: 'Summarize', exact: true }));
  assert.equal(calls.find((c) => c.name === 'summarize_link').args.thinking, false);
  await act(async () => {
    emitStatus('writing');
    for (const chunk of fixture.formatted_output.chunks) emitDelta('answer', chunk);
    emitStatus('ready');
    resolveRun();
  });
  await tick();
  const article = paper();
  assert.equal(article.firstElementChild.tagName, 'P', 'The introduction must not be a list item');
  const headings = [...article.querySelectorAll(':scope > h2')];
  assert.deepEqual(headings.map((h) => h.textContent), ['Key points', 'Details']);
  assert.equal(headings[0].nextElementSibling.tagName, 'UL');
  assert.ok(headings[0].nextElementSibling.children.length >= 3);
  assert.equal(headings[1].nextElementSibling.tagName, 'P');
  assert.ok(![...article.querySelectorAll('li')].some((li) => /^##\s/.test(li.textContent)));
  await click(copy());
  assert.equal(calls.find((c) => c.name === 'copy_text').args.text, generated.trim());
});

test('a model that returned no thinking despite the request is explained after reopening', async () => {
  localStorage.setItem('ghostpen-summary-reader', JSON.stringify({ showThinking: true }));
  snapshot = { ...empty, state: 'ready', thinking_requested: true, markdown: answer, revision: 1 };
  await mount();
  assert.match(screen.getByRole('region', { name: 'Model thinking' }).textContent, /didn't include thinking, even though it was requested/);
});

test('received thinking remains available after cancellation without enabling Copy or Read', async () => {
  await mount();
  await status('writing');
  await delta('thinking', thoughts);
  await click(screen.getByRole('button', { name: 'Stop', exact: true }));
  await click(toggle());
  assert.match(screen.getByRole('alert').textContent, /Cancelled/);
  assert.match(screen.getByRole('region', { name: 'Model thinking' }).textContent, /Private reasoning/);
  assert.equal(copy().disabled, true);
  assert.equal(read().disabled, true);
});

test('structured stream and reopened snapshot give identical summary, thinking and Copy/TTS payloads', async () => {
  await mount();
  await status('writing');
  await delta('thinking', thoughts);
  await click(toggle());
  assert.equal(paper(), null);
  await delta('answer', answer);
  await status('ready');
  const before = paper().innerHTML;
  for (const visible of [true, false]) {
    if (!visible) await click(toggle());
    await click(copy());
    await click(read());
    assert.equal(paper().innerHTML, before);
  }
  assert.deepEqual(calls.filter((c) => c.name === 'copy_text').map((c) => c.args.text), [answer, answer]);
  assert.deepEqual(calls.filter((c) => c.name === 'tts_speak').map((c) => c.args.text), [answer, answer]);
  await unmount();
  await mount();
  assert.equal(paper().innerHTML, before);
  assert.equal(document.body.textContent.includes(thoughts), false);
  await click(toggle());
  assert.match(screen.getByRole('region', { name: 'Model thinking' }).textContent, /Private reasoning/);
});

test('ordinary Thinking Process headings and literal tokens remain readable and copyable', async () => {
  const text = '## Thinking Process:\n\nThis article describes how people solve problems. Literal `<think>` and `<channel|>` tokens.';
  snapshot = { ...empty, state: 'ready', markdown: text, revision: 1 };
  await mount();
  assert.match(paper().textContent, /This article describes/);
  assert.match(paper().textContent, /<think>/);
  await click(copy());
  await click(read());
  assert.equal(calls.find((c) => c.name === 'copy_text').args.text, text);
  assert.equal(calls.find((c) => c.name === 'tts_speak').args.text, text);
  await click(toggle());
  assert.match(screen.getByRole('region', { name: 'Model thinking' }).textContent, /Thinking wasn't requested/);
});

test('events arriving around snapshot hydration are neither lost nor duplicated', async () => {
  let resolveSnapshot;
  const pending = new Promise((resolve) => { resolveSnapshot = resolve; });
  getSnapshot = () => pending;
  await mount();
  act(() => {
    emitStatus('writing');
    emitDelta('thinking', thoughts);
    emitDelta('answer', 'First.');
  });
  const captured = { ...snapshot };
  act(() => emitDelta('answer', ' Second.'));
  await act(async () => resolveSnapshot(captured));
  await tick();
  assert.equal(paper().textContent.trim(), 'First. Second.');
  await click(toggle());
  assert.equal(screen.getByRole('region', { name: 'Model thinking' }).textContent.match(/Analyze/g).length, 1);
  await click(copy());
  assert.equal(calls.find((c) => c.name === 'copy_text').args.text, 'First. Second.');
});

test('a new run clears both channels and overflow errors leave thinking out of reading actions', async () => {
  snapshot = { ...empty, state: 'ready', markdown: answer, thinking: thoughts, revision: 4 };
  await mount();
  await status('fetching');
  assert.equal(paper(), null);
  assert.equal(copy().disabled, true);
  await delta('thinking', 'More private reasoning.');
  act(() => emitStatus('error', "The model's output exceeded the 1 MiB limit. Try a shorter summary."));
  await tick();
  assert.match(screen.getByRole('alert').textContent, /exceeded the 1 MiB limit/);
  assert.equal(copy().disabled, true);
  assert.equal(read().disabled, true);
});

test('old/corrupt settings default to hidden and thinking HTML stays inert', async () => {
  localStorage.setItem('ghostpen-summary-reader', '{broken');
  snapshot = { ...empty, state: 'ready', markdown: answer, thinking: '<img src=x onerror="alert(1)">', revision: 2 };
  await mount();
  assert.equal(toggle().checked, false);
  await click(toggle());
  assert.equal(screen.getByRole('region', { name: 'Model thinking' }).querySelector('img'), null);
  await unmount();
  localStorage.setItem('ghostpen-summary-reader', JSON.stringify({ size: 20, font: 'sans', spacing: 'compact' }));
  await mount();
  assert.equal(toggle().checked, false);
  assert.equal(screen.getByLabelText('Current font size').textContent, '20px');
});
