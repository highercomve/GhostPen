const assert = require('node:assert/strict');
const { test, before, beforeEach, afterEach, after } = require('node:test');
const { mkdtempSync, rmSync } = require('node:fs');
const path = require('node:path');
const { tmpdir } = require('node:os');
const { build } = require('esbuild');
const { JSDOM } = require('jsdom');

const dom = new JSDOM('<!doctype html><html><body></body></html>', { url: 'http://localhost/meetings', pretendToBeVisual: true });
for (const key of ['window', 'document', 'navigator', 'HTMLElement', 'Element', 'Node', 'Event', 'MouseEvent', 'localStorage'])
  Object.defineProperty(globalThis, key, { configurable: true, value: dom.window[key] });
globalThis.IS_REACT_ACT_ENVIRONMENT = true;
const React = require('react');
const { act } = React;
const { createRoot } = require('react-dom/client');
const { getQueriesForElement, fireEvent } = require('@testing-library/dom');
const screen = getQueriesForElement(document.body);
const directory = mkdtempSync(path.join(tmpdir(), 'ghostpen-meetings-test-'));
let Meetings, root, calls, listeners, recorder, startResult, savedNotes, notesError;
const idle = { starting: false, stopping: false, captions_running: false, recording: null };
const meeting = (id, state = 'ready') => ({
  id, audio: '', folder: '/meetings/' + id, busy: state !== 'ready',
  meeting: { version: 1, title: id === 'saved' ? 'Product planning' : 'New recording', titleEdited: false,
    startedAt: 1, startedLocal: '20 Oct, 10:30', durationMs: 120000, state, message: '', mic: true,
    model: 'base', language: 'en', speakers: [{ id: 'me', name: 'Me' }],
    segments: state === 'ready' ? [{ start: 0, end: 8, speaker: 'me', text: 'Ship the accessibility improvements.' }] : [],
    final: [], summary: '## Decisions\n\nShip the accessibility improvements.', notes: [] },
});

before(async () => {
  const outfile = path.join(directory, 'Meetings.cjs');
  await build({ entryPoints: [path.join(__dirname, '../src/Meetings.tsx')], outfile, bundle: true,
    platform: 'node', format: 'cjs', jsx: 'automatic', external: ['mermaid'], plugins: [{ name: 'native-bridge', setup(b) {
      b.onResolve({ filter: /^\.\/oriel$/ }, () => ({ path: 'oriel', namespace: 'test' }));
      b.onLoad({ filter: /.*/, namespace: 'test' }, () => ({ contents: 'export const orielWindow = {}; export const openExternal = async()=>{};' }));
      b.onResolve({ filter: /^react(?:\/.*)?$/ }, ({ path: specifier }) => ({ path: require.resolve(specifier), external: true }));
    } }] });
  Meetings = require(outfile).default;
});

beforeEach(() => {
  calls = []; listeners = new Map(); recorder = { ...idle }; startResult = null;
  savedNotes = new Map(); notesError = false; localStorage.clear();
  window.oriel = { listen(name, callback) {
    if (!listeners.has(name)) listeners.set(name, new Set());
    listeners.get(name).add(callback);
    return () => listeners.get(name).delete(callback);
  }, async invoke(name, args) {
    calls.push({ name, args });
    if (name === 'meetings_recording_status') return { ...recorder };
    if (name === 'meetings_start_recording') {
      if (startResult) return startResult();
      recorder = { ...idle, recording: { id: 'new', seconds: 3 } };
      return recorder.recording;
    }
    if (name === 'meetings_stop_recording') { recorder = { ...idle }; return null; }
    if (name === 'meetings_list') return [
      ...(recorder.recording ? [{ ...meeting('new', 'recording').meeting, id: 'new', speakers: 0, preview: '' }] : []),
      { ...meeting('saved').meeting, id: 'saved', speakers: 1, preview: 'Ship the accessibility improvements.' },
    ].filter((m) => !args.query || m.title.toLowerCase().includes(args.query.toLowerCase()));
    if (name === 'meetings_get') return { ...meeting(args.id, args.id === 'new' && recorder.recording ? 'recording' : 'ready'), personalNotes: savedNotes.get(args.id) ?? '' };
    if (name === 'meetings_save_notes') {
      if (notesError) throw new Error('Disk unavailable');
      savedNotes.set(args.id, args.text); return null;
    }
    if (name === 'meetings_voices') return [];
    return null;
  } };
});
afterEach(async () => {
  if (root) await act(async () => root.unmount());
  root = null; document.body.replaceChildren();
});
after(() => { dom.window.close(); rmSync(directory, { recursive: true, force: true }); });
const wait = (ms = 230) => act(async () => new Promise((resolve) => setTimeout(resolve, ms)));
async function mount() {
  const el = document.createElement('div'); document.body.append(el); root = createRoot(el);
  await act(async () => root.render(React.createElement(React.StrictMode, null, React.createElement(Meetings))));
  await wait();
}
async function click(el) { await act(async () => fireEvent.click(el)); await wait(); }

test('record from Meetings without opening captions, then stop and save', async () => {
  await mount();
  await click(screen.getByRole('button', { name: 'Record meeting' }));
  assert.ok(screen.getByRole('button', { name: 'Stop and save' }));
  assert.ok(screen.getByRole('heading', { name: 'New recording' }));
  assert.match(screen.getByRole('region', { name: 'Meeting recorder' }).textContent, /Recording 00:03/);
  await click(screen.getByRole('button', { name: 'Stop and save' }));
  assert.ok(screen.getByRole('button', { name: 'Record meeting' }));
  assert.equal(calls.filter((c) => c.name === 'meetings_start_recording').length, 1);
  assert.equal(calls.filter((c) => c.name === 'meetings_stop_recording').length, 1);
  assert.equal(calls.some((c) => ['captions_start', 'open_captions'].includes(c.name)), false);
});

test('live captions block a new recording and are not stopped implicitly', async () => {
  recorder = { ...idle, captions_running: true };
  await mount();
  assert.equal(screen.getByRole('button', { name: 'Record meeting' }).disabled, true);
  assert.match(screen.getByRole('region', { name: 'Meeting recorder' }).textContent, /Stop them before starting/);
  assert.equal(calls.some((c) => c.name === 'captions_stop'), false);
});

test('closing the page leaves capture running and reopening restores Stop', async () => {
  recorder = { ...idle, recording: { id: 'new', seconds: 42 } };
  await mount();
  assert.ok(screen.getByRole('button', { name: 'Stop and save' }));
  await act(async () => root.unmount()); root = null; document.body.replaceChildren();
  assert.equal(calls.some((c) => c.name === 'meetings_stop_recording'), false);
  await mount();
  assert.match(screen.getByRole('region', { name: 'Meeting recorder' }).textContent, /00:42/);
  assert.ok(screen.getByRole('button', { name: 'Stop and save' }));
});

test('start errors are visible and retry remains available', async () => {
  startResult = () => { throw new Error('No system audio source'); };
  await mount();
  await click(screen.getByRole('button', { name: 'Record meeting' }));
  assert.match(screen.getByRole('alert').textContent, /No system audio source/);
  assert.equal(screen.getByRole('button', { name: 'Record meeting' }).disabled, false);
  startResult = null;
  await click(screen.getByRole('button', { name: 'Record meeting' }));
  assert.ok(screen.getByRole('button', { name: 'Stop and save' }));
});

test('a slow start can be cancelled without opening captions', async () => {
  let finish;
  startResult = () => new Promise((resolve) => { finish = resolve; });
  await mount();
  await click(screen.getByRole('button', { name: 'Record meeting' }));
  await click(screen.getByRole('button', { name: 'Cancel start' }));
  await act(async () => finish(null)); await wait();
  assert.ok(screen.getByRole('button', { name: 'Record meeting' }));
  assert.ok(calls.some((c) => c.name === 'meetings_stop_recording'));
});

test('recording does not prevent browsing and searching saved meetings', async () => {
  recorder = { ...idle, recording: { id: 'new', seconds: 4 } };
  await mount();
  await click(screen.getByRole('option', { name: /Product planning/ }));
  assert.ok(screen.getByRole('heading', { name: 'Product planning' }));
  act(() => fireEvent.change(screen.getByRole('searchbox', { name: 'Search meetings' }), { target: { value: 'product' } }));
  await wait(1150);
  assert.equal(screen.getByRole('searchbox', { name: 'Search meetings' }).value, 'product');
  assert.ok(screen.getByRole('heading', { name: 'Product planning' }));
  assert.ok(screen.getByRole('button', { name: 'Stop and save' }));
  await click(screen.getByRole('tab', { name: 'Summary' }));
  assert.ok(screen.getByRole('heading', { name: 'Decisions' }));
});

test('personal notes autosave during recording and survive reopening', async () => {
  recorder = { ...idle, recording: { id: 'new', seconds: 4 } };
  await mount();
  await click(screen.getByRole('tab', { name: 'Notes' }));
  act(() => fireEvent.change(screen.getByRole('textbox', { name: 'Your meeting notes' }), { target: { value: '## Next steps\n\n- Send the prototype.' } }));
  await wait(850);
  assert.equal(savedNotes.get('new'), '## Next steps\n\n- Send the prototype.');
  assert.equal(calls.some(c => c.name === 'meetings_update'), false);
  await click(screen.getByRole('button', { name: 'Preview' }));
  assert.ok(screen.getByRole('heading', { name: 'Next steps' }));
  await act(async () => root.unmount()); root = null; document.body.replaceChildren();
  await mount(); await click(screen.getByRole('tab', { name: 'Notes' }));
  assert.equal(screen.getByRole('textbox', { name: 'Your meeting notes' }).value, savedNotes.get('new'));
});

test('switching meetings flushes notes to the correct meeting', async () => {
  recorder = { ...idle, recording: { id: 'new', seconds: 4 } };
  await mount(); await click(screen.getByRole('tab', { name: 'Notes' }));
  act(() => fireEvent.change(screen.getByRole('textbox', { name: 'Your meeting notes' }), { target: { value: 'Only for this recording' } }));
  await click(screen.getByRole('option', { name: /Product planning/ }));
  assert.equal(savedNotes.get('new'), 'Only for this recording');
  assert.equal(screen.getByRole('textbox', { name: 'Your meeting notes' }).value, '');
  assert.equal(savedNotes.has('saved'), false);
});

test('failed notes save preserves the draft and can be retried', async () => {
  notesError = true;
  await mount(); await click(screen.getByRole('tab', { name: 'Notes' }));
  act(() => fireEvent.change(screen.getByRole('textbox', { name: 'Your meeting notes' }), { target: { value: 'Keep this draft' } }));
  await click(screen.getByRole('button', { name: 'Save notes' }));
  assert.match(screen.getByRole('alert').textContent, /Disk unavailable/);
  assert.equal(localStorage.getItem('ghostpen:meeting-notes:/meetings/saved'), 'Keep this draft');
  notesError = false;
  await click(screen.getByRole('button', { name: 'Save notes' }));
  assert.equal(savedNotes.get('saved'), 'Keep this draft');
  assert.equal(localStorage.getItem('ghostpen:meeting-notes:/meetings/saved'), null);
});

test('editing during a slow notes save keeps the newest text', async () => {
  const invoke = window.oriel.invoke;
  let release, first = true;
  const gate = new Promise(resolve => { release = resolve; });
  window.oriel.invoke = async (name, args) => {
    if (name === 'meetings_save_notes' && first) { first = false; await gate; }
    return invoke(name, args);
  };
  await mount(); await click(screen.getByRole('tab', { name: 'Notes' }));
  act(() => fireEvent.change(screen.getByRole('textbox', { name: 'Your meeting notes' }), { target: { value: 'First draft' } }));
  await click(screen.getByRole('button', { name: 'Save notes' }));
  act(() => fireEvent.change(screen.getByRole('textbox', { name: 'Your meeting notes' }), { target: { value: 'Latest draft' } }));
  await wait(850);
  await act(async () => release()); await wait();
  assert.equal(savedNotes.get('saved'), 'Latest draft');
  assert.equal(screen.getByRole('textbox', { name: 'Your meeting notes' }).value, 'Latest draft');
});

test('Follow playback is an accessible sliding switch', async () => {
  await mount();
  const toggle = screen.getByRole('switch', { name: 'Follow playback' });
  assert.equal(toggle.tagName, 'BUTTON');
  assert.equal(toggle.getAttribute('aria-checked'), 'true');
  assert.ok(toggle.querySelector('.switch-thumb'));
  await click(toggle);
  assert.equal(toggle.getAttribute('aria-checked'), 'false');
});

test('meeting chat is separate from Summary and saves latest notes before asking', async () => {
  await mount();
  await click(screen.getByRole('tab', { name: 'Summary' }));
  assert.ok(screen.getByRole('heading', { name: 'Decisions' }));
  assert.equal(screen.queryByRole('region', { name: 'Meeting chat' }), null);
  await click(screen.getByRole('tab', { name: 'Notes' }));
  act(() => fireEvent.change(screen.getByRole('textbox', { name: 'Your meeting notes' }), { target: { value: 'Launch code: ORCHID' } }));
  await click(screen.getByRole('tab', { name: 'Chat' }));
  assert.ok(screen.getByRole('region', { name: 'Meeting chat' }));
  assert.equal(screen.queryByRole('heading', { name: 'Decisions' }), null);
  act(() => fireEvent.change(screen.getByRole('textbox', { name: 'Ask a question about this meeting…' }), { target: { value: 'What is the launch code?' } }));
  await click(screen.getByRole('button', { name: 'Send', exact: true }));
  assert.equal(savedNotes.get('saved'), 'Launch code: ORCHID');
  const askAt = calls.findIndex(c => c.name === 'meetings_ask');
  assert.ok(askAt > calls.findIndex(c => c.name === 'meetings_save_notes'));
  assert.equal(calls[askAt].args.prompt, 'What is the launch code?');
});

test('meeting answers stream as they arrive and ignore another meeting', async () => {
  await mount(); await click(screen.getByRole('tab', { name: 'Chat' }));
  const emit = async payload => act(async () => {
    for (const callback of listeners.get('ghostpen://meeting-answer') ?? []) callback(payload);
  });
  await emit({ id: 'saved', prompt: 'What is the code?', text: '', reset: true });
  await emit({ id: 'saved', prompt: 'What is the code?', text: 'The code is **OR', reset: false });
  assert.match(screen.getByRole('region', { name: 'Meeting chat' }).textContent, /The code is/);
  await emit({ id: 'new', prompt: 'Other meeting', text: 'UNRELATED', reset: false });
  await emit({ id: 'saved', prompt: 'What is the code?', text: 'CHID**.', reset: false });
  assert.match(screen.getByRole('region', { name: 'Meeting chat' }).textContent, /The code is ORCHID/);
  assert.doesNotMatch(screen.getByRole('region', { name: 'Meeting chat' }).textContent, /UNRELATED/);
  assert.match(screen.getByRole('region', { name: 'Meeting chat' }).textContent, /Generating answer/);
});
