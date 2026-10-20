const assert = require('node:assert/strict');
const { test, before, beforeEach, after } = require('node:test');
const { mkdtempSync, rmSync } = require('node:fs');
const { tmpdir } = require('node:os');
const path = require('node:path');
const { build } = require('esbuild');
const { JSDOM } = require('jsdom');

const dom = new JSDOM('<!doctype html><html><body></body></html>');
for (const key of ['window', 'document', 'Element', 'DOMParser', 'XMLSerializer']) {
  Object.defineProperty(globalThis, key, { configurable: true, value: dom.window[key] });
}
window.matchMedia = () => ({ matches: false });
Object.defineProperty(dom.window.SVGElement.prototype, 'viewBox', {
  get() {
    const [, , width, height] = (this.getAttribute('viewBox') || '0 0 100 80').split(' ').map(Number);
    return { baseVal: { width, height } };
  },
});
globalThis.Image = class {
  set src(value) { queueMicrotask(() => this.onload()); }
};
const directory = mkdtempSync(path.join(tmpdir(), 'ghostpen-diagrams-test-'));
let diagrams, calls, canvasFailure;

before(async () => {
  const outfile = path.join(directory, 'diagrams.cjs');
  await build({
    entryPoints: [path.join(__dirname, '../src/diagrams.ts')], outfile,
    bundle: true, platform: 'node', format: 'cjs',
    plugins: [{ name: 'mermaid-fixture', setup(b) {
      b.onResolve({ filter: /^mermaid$/ }, () => ({ path: 'mermaid', namespace: 'test' }));
      b.onLoad({ filter: /.*/, namespace: 'test' }, () => ({ contents: 'export default { initialize() {}, render: (...args) => window.renderFixture(...args) };' }));
    } }],
  });
  diagrams = require(outfile);
});

beforeEach(() => {
  document.body.replaceChildren();
  calls = [];
  canvasFailure = false;
  window.renderFixture = async (id, source, stage) => {
    calls.push(source);
    assert.ok(stage.isConnected);
    if (source.includes('bad diagram')) {
      stage.innerHTML = '<svg><text>Syntax error</text></svg>';
      throw new Error('Invalid Mermaid');
    }
    const size = source.includes('oversized') ? '0 0 10000 10000' : '0 0 100 80';
    return { svg: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${size}"><text>Rendered diagram</text></svg>` };
  };
  dom.window.HTMLCanvasElement.prototype.getContext = function () {
    return canvasFailure ? null : { fillRect() {}, drawImage() {}, fillStyle: '' };
  };
  dom.window.HTMLCanvasElement.prototype.toDataURL = () => 'data:image/jpeg;base64,SlBFRw==';
});
after(() => { dom.window.close(); rmSync(directory, { recursive: true, force: true }); });

test('invalid reader diagrams preserve escaped source and leave no Mermaid error elements', async () => {
  const root = document.createElement('article');
  const source = 'bad diagram <script>alert(1)</script>';
  root.innerHTML = '<pre class="mermaid"></pre><pre class="mermaid">flowchart LR\n A-->B</pre>';
  root.firstChild.textContent = source;
  document.body.append(root);
  await Promise.all([diagrams.renderDiagrams(root), diagrams.renderDiagrams(root)]);
  assert.equal(root.firstChild.textContent, source);
  assert.equal(root.firstChild.querySelector('script'), null);
  assert.equal(root.firstChild.dataset.diagram, 'failed');
  assert.equal(root.lastChild.dataset.diagram, 'done');
  assert.equal(root.querySelectorAll('svg').length, 1);
  assert.equal(document.body.children.length, 1);
  assert.equal(calls.length, 2, 'concurrent renders must not process the same node twice');
});

test('export finds real fences, normalizes CRLF and deduplicates repeated diagrams', async () => {
  const markdown = 'Inline ```mermaid is prose.\r\n\r\n~~~ MERMAID\r\nflowchart LR\r\n A-->B\r\n~~~\r\n```mermaid\r\nflowchart LR\r\n A-->B\r\n```\r\n```text\r\nnot a diagram\r\n```\r\n```mermaid\r\nsequenceDiagram\r\n A->>B: hello';
  const images = await diagrams.exportDiagrams(markdown);
  assert.deepEqual(images.map(({ key, width, height }) => ({ key, width, height })), [
    { key: 'flowchart LR\n A-->B', width: 200, height: 160 },
    { key: 'sequenceDiagram\n A->>B: hello', width: 200, height: 160 },
  ]);
  assert.ok(calls.every((source) => source.includes("'theme':'neutral'")));
  assert.equal(document.body.children.length, 0);
});

test('a failed diagram does not prevent later diagrams from exporting', async () => {
  const images = await diagrams.exportDiagrams('```mermaid\nbad diagram\n```\n```mermaid\nflowchart LR\n A-->B\n```');
  assert.equal(images.length, 1);
  assert.match(images[0].key, /flowchart/);
  assert.equal(document.body.children.length, 0);
});

test('rasterization failures and excessive dimensions keep source fallback without leaking DOM', async () => {
  canvasFailure = true;
  assert.deepEqual(await diagrams.exportDiagrams('```mermaid\nflowchart LR\n A-->B\n```'), []);
  assert.equal(document.body.children.length, 0);
  canvasFailure = false;
  assert.deepEqual(await diagrams.exportDiagrams('```mermaid\noversized\n```'), []);
  assert.equal(document.body.children.length, 0);
});
