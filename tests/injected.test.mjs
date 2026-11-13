import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('../src-tauri/src/injected.js', import.meta.url), 'utf8');
const policy = JSON.parse(readFileSync(new URL('../src-tauri/src/link-policy.json', import.meta.url), 'utf8'));
const cases = JSON.parse(readFileSync(new URL('./link-cases.json', import.meta.url), 'utf8'));

function harness({ headInitially = true, bridge = true, windowLabel = 'main', location = 'https://teams.microsoft.com/v2/' } = {}) {
  const calls = [];
  const listeners = new Map();
  const documentListeners = new Map();
  const observers = [];
  const root = { tagName: 'HTML' };
  const body = { tagName: 'BODY', parent: root };
  const title = { tagName: 'TITLE' };
  const head = { tagName: 'HEAD', parent: root, title, querySelector: () => head.title };
  title.parent = head;
  let titleText = 'Microsoft Teams';
  let titleReads = 0;
  let observerCalls = 0;
  const document = {
    head: headInitially ? head : null, documentElement: root, body, hidden: false,
    addEventListener: (name, callback) => documentListeners.set(name, callback),
    get title() { titleReads++; return titleText; },
    set title(value) { titleText = value; }
  };
  const window = {
    addEventListener: (name, callback, capture) => listeners.set(name, { callback, capture }),
    ...(bridge ? { __TAURI_INTERNALS__: { invoke: (command, args) => {
      calls.push({ command, args }); return Promise.resolve();
    } } } : {})
  };
  class MutationObserver {
    constructor(callback) { this.callback = callback; this.targets = []; observers.push(this); }
    observe(target, options) { this.targets.push({ target, options }); }
    disconnect() { this.targets = []; }
  }
  function mutate(target) {
    for (const observer of observers) {
      if (observer.targets.some(observed => {
        if (target === observed.target) return true;
        if (!observed.options.subtree) return false;
        for (let parent = target.parent; parent; parent = parent.parent) {
          if (parent === observed.target) return true;
        }
        return false;
      })) {
        observerCalls++;
        observer.callback();
      }
    }
  }
  const context = vm.createContext({
    window, document, location: { href: location },
    URL, MutationObserver, console, setInterval: () => {}, setTimeout: () => {}, policy, windowLabel
  });
  vm.runInContext(`(${source})(policy, windowLabel)`, context);
  function click(href, overrides = {}) {
    const anchor = { tagName: 'A', href, hasAttribute: name => name === 'download' && !!overrides.download };
    const event = {
      type: 'click', button: 0, isTrusted: true, defaultPrevented: false,
      composedPath: () => [{ tagName: 'SPAN' }, anchor, body, root],
      preventDefault() { this.defaultPrevented = true; },
      stopImmediatePropagation() { this.stopped = true; }, ...overrides
    };
    listeners.get(event.type).callback(event);
    return event;
  }
  return { calls, listeners, documentListeners, document, root, body, head, title,
    observers, mutate, click, window, reads: () => titleReads, observerCalls: () => observerCalls };
}

for (const { url, external } of cases) {
  test(`link routing: ${url}`, () => {
    const app = harness();
    const event = app.click(url);
    const opened = app.calls.filter(call => call.command === 'open_external_link');
    assert.equal(opened.length, external ? 1 : 0);
    assert.equal(event.defaultPrevented, external);
    if (external) {
      assert.equal(opened[0].args.url, new URL(url).href);
      assert.equal(event.stopped, true);
    }
  });
}

test('same-frame and target=_blank links share the explicit scoped command', () => {
  const app = harness();
  assert.equal(app.listeners.get('click').capture, true);
  app.click('https://example.org', { target: '_self' });
  app.click('https://example.org', { target: '_blank' });
  assert.equal(app.calls.filter(call => call.command === 'open_external_link').length, 2);
  assert.ok(app.calls.every(call => !call.command.startsWith('plugin:opener')));
});

test('middle clicks work, but right clicks, synthetic clicks and downloads are left alone', () => {
  const app = harness();
  assert.equal(app.click('https://example.org', { type: 'auxclick', button: 1 }).defaultPrevented, true);
  for (const options of [{ button: 2 }, { isTrusted: false }, { download: true }, { defaultPrevented: true }]) {
    const before = app.calls.length;
    app.click('https://example.org', options);
    assert.equal(app.calls.length, before);
  }
});

test('without the IPC bridge, link navigation is not silently cancelled', () => {
  const app = harness({ bridge: false });
  assert.equal(app.click('https://example.org').defaultPrevented, false);
});

test('only the main Teams document captures links, matching the scoped capability', () => {
  for (const options of [{ windowLabel: 'auth-1' }, { location: 'https://tenant.sharepoint.com/' }, { location: 'https://login.microsoftonline.com/' }]) {
    const app = harness(options);
    assert.equal(app.listeners.has('click'), false);
    assert.equal(app.listeners.has('auxclick'), false);
  }
});

test('early injection waits for head and never watches the whole document', () => {
  const app = harness({ headInitially: false });
  assert.equal(app.observers.length, 0);
  app.document.head = app.head;
  app.documentListeners.get('DOMContentLoaded')();
  assert.ok(app.observers.flatMap(observer => observer.targets).every(({ target }) => target !== app.root && target !== app.body));
  assert.equal(app.observers.find(observer => observer.targets.some(({ target }) => target === app.head)).targets[0].options.subtree, undefined);
});

test('10000 editor/list DOM changes cause no title scans or native IPC calls', () => {
  const app = harness();
  const before = app.reads();
  for (let index = 0; index < 10000; index++) app.mutate({ parent: app.body });
  assert.equal(app.reads(), before);
  assert.equal(app.observerCalls(), 0);
  assert.equal(app.calls.length, 0);
});

test('title updates and title replacement still update the badge without duplicates', () => {
  const app = harness();
  app.document.title = '(3) Microsoft Teams';
  app.mutate(app.title);
  app.mutate(app.title);
  assert.deepEqual(app.calls.map(call => [call.command, call.args.count]), [['set_unread_count', 3]]);
  app.head.title = { tagName: 'TITLE', parent: app.head };
  app.document.title = '(5) Microsoft Teams';
  app.mutate(app.head);
  app.mutate(app.head.title);
  assert.deepEqual(app.calls.map(call => call.args.count), [3, 5]);
});
