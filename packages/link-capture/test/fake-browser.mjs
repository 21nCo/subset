// A fake browser behind extfn's real facade (`createBrowserFacade` of @extfn/core 0.1.0, which ships no fake of its
// own). TEMPORARY until extfn 0.2.0 (SFO-44) ships its fake facade, per the SET-182 owner amendment. Every call is recorded. `scripting.executeScript` runs the injected function the way a browser does: from its
// source text in a fresh scope, so a function that reaches for a module import fails here as it would in a tab, with
// the page's globals set and its result structured-cloned.
import { createBrowserFacade } from '@extfn/core';
import { DomUtils, parseDocument } from 'htmlparser2';

/**
 * `storage.before(op, arg)` runs (and may delay or throw) before each `storage.local` get, set or remove takes effect;
 * `storage.quotaBytes` makes a set that would exceed it reject as Chromium does, writing nothing. `grant` is what
 * `permissions.request` answers.
 */
export function createFakeBrowser({ target = 'chromium-mv3', tabs = [], page, injectError, menuItems = [], storage = {}, grant = true } = {}) {
  const calls = [];
  const local = new Map();
  const menus = new Set(menuItems);
  const granted = new Set();
  const record = (path, ...args) => calls.push([path, ...args]);
  const forbidden = (path) => async (...args) => {
    record(path, ...args);
    throw new Error(`${path} must not be used`);
  };

  const raw = {
    runtime: {},
    tabs: {
      async query(query) {
        record('tabs.query', query);
        return structuredClone(tabs);
      }
    },
    scripting: {
      async executeScript(injection) {
        record('scripting.executeScript', { target: injection.target, args: injection.args });
        if (injectError) throw injectError;
        return [{ frameId: 0, result: runInPage(page, injection.func, injection.args) }];
      }
    },
    storage: {
      local: {
        async get(key) {
          record('storage.local.get', key);
          await storage.before?.('get', key);
          // `null` reads everything, as in the browsers.
          if (key === null) return structuredClone(Object.fromEntries(local));
          return local.has(key) ? { [key]: structuredClone(local.get(key)) } : {};
        },
        async set(items) {
          record('storage.local.set', structuredClone(items));
          await storage.before?.('set', items);
          const after = { ...Object.fromEntries(local), ...items };
          if (storage.quotaBytes !== undefined && JSON.stringify(after).length > storage.quotaBytes) {
            throw new Error('QUOTA_BYTES quota exceeded');
          }
          for (const [key, value] of Object.entries(items)) local.set(key, structuredClone(value));
        },
        async remove(keys) {
          record('storage.local.remove', keys);
          await storage.before?.('remove', keys);
          for (const key of [keys].flat()) local.delete(key);
        }
      },
      sync: { get: forbidden('storage.sync.get'), set: forbidden('storage.sync.set'), remove: forbidden('storage.sync.remove') }
    },
    action: {
      async setBadgeText(details) {
        record('action.setBadgeText', details);
      },
      async setTitle(details) {
        record('action.setTitle', details);
      }
    },
    contextMenus: {
      async create(properties) {
        record('contextMenus.create', properties);
        // Chromium refuses a duplicate id, which is why registration removes the item first.
        if (menus.has(properties.id)) throw new Error(`Cannot create item with duplicate id ${properties.id}`);
        menus.add(properties.id);
        return properties.id;
      },
      async remove(id) {
        record('contextMenus.remove', id);
        if (!menus.delete(id)) throw new Error(`Cannot find menu item with id ${id}`);
      }
    },
    permissions: {
      async request(request) {
        record('permissions.request', request);
        if (grant === true) for (const origin of request.origins) granted.add(origin);
        return grant;
      },
      async contains(request) {
        record('permissions.contains', request);
        return request.origins.every((origin) => granted.has(origin));
      },
      async remove(request) {
        record('permissions.remove', request);
        return request.origins.map((origin) => granted.delete(origin)).every(Boolean);
      }
    }
  };

  return { browser: createBrowserFacade({ raw, target }), calls, local, menus, paths: () => calls.map(([path]) => path) };
}

/**
 * A page for `executeScript`: `head` is the `<head>` markup, parsed into a small DOM, or null for a document without
 * one. `stats` counts the nodes the page script visits and the characters of `outerHTML` it builds. `root` is the
 * document element: `html` (an HTMLElement, with `lang`), `svg` or `xml` (an Element with no `lang` property), or null.
 */
export function fakePage({ url, title = '', head = '<head></head>', lang = '', contentType = 'text/html', selection = '', root = 'html' }) {
  return { url, title, head, lang, contentType, selection, root, stats: { visits: 0, serialized: 0, seen: new WeakSet() } };
}

const NODE_TYPES = { tag: 1, script: 1, style: 1, text: 3, cdata: 4, comment: 8 };

/** The DOM reads `readPage` makes, over htmlparser2 nodes. The head's own outerHTML throws: it must not be built whole. */
function fakeHead(markup, stats) {
  const document = parseDocument(markup);
  const headNode = DomUtils.findOne((node) => node.name === 'head', document.children);
  const wrapped = new WeakMap();
  const wrap = (node) => {
    if (!node) return null;
    if (wrapped.has(node)) return wrapped.get(node);
    const element = (sibling) => {
      while (sibling && NODE_TYPES[sibling.type] !== 1) sibling = sibling.next;
      return wrap(sibling);
    };
    const view = {
      get nodeType() {
        if (!stats.seen.has(view)) stats.visits++, stats.seen.add(view);
        return NODE_TYPES[node.type] ?? 9;
      },
      get localName() { return node.name; },
      get attributes() { return Object.entries(node.attribs ?? {}).map(([name, value]) => ({ name, value })); },
      get length() { return node.data.length; },
      get firstChild() { return wrap(node.children?.[0]); },
      get nextSibling() { return node === headNode ? null : wrap(node.next); },
      get parentNode() { return wrap(node.parent); },
      get firstElementChild() { return element(node.children?.[0]); },
      get nextElementSibling() { return element(node.next); },
      get outerHTML() {
        if (node === headNode) throw new Error('head.outerHTML must not be read');
        const html = DomUtils.getOuterHTML(node, { encodeEntities: 'utf8' }); // as browsers: only &, <, > and quotes escaped
        stats.serialized += html.length;
        return html;
      }
    };
    wrapped.set(node, view);
    return view;
  };
  return wrap(headNode);
}

function documentElement(page) {
  if (page.root === null) return null;
  // `lang` is an HTMLElement attribute: an SVG or XML root has only the content attribute.
  if (page.root === 'svg' || page.root === 'xml') return { getAttribute: (name) => (name === 'lang' ? page.lang || null : null) };
  return { lang: page.lang };
}

/** Runs `func` as a browser injects it: rebuilt from its source in a fresh scope, with `page` as the globals. */
export function runInPage(page, func, args) {
  const isolated = new Function(`return (${func.toString()});`)();
  return structuredClone(withPage(page, () => isolated(...args)));
}

function withPage(page, run) {
  const names = ['document', 'window', 'location'];
  const saved = names.map((name) => Object.getOwnPropertyDescriptor(globalThis, name));
  const values = {
    document: {
      head: page.head === null ? null : fakeHead(page.head, page.stats),
      title: page.title,
      documentElement: documentElement(page),
      contentType: page.contentType
    },
    window: { getSelection: () => (page.selection === null ? null : { toString: () => page.selection }) },
    location: { href: page.url }
  };
  for (const name of names) Object.defineProperty(globalThis, name, { value: values[name], configurable: true, writable: true });
  try {
    return run();
  } finally {
    names.forEach((name, index) => {
      if (saved[index]) Object.defineProperty(globalThis, name, saved[index]);
      else delete globalThis[name];
    });
  }
}
