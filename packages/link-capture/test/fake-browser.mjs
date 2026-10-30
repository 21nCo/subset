// A fake browser behind extfn's real facade (`createBrowserFacade` of @extfn/core 0.1.0, which ships no fake of its
// own). Every call is recorded. `scripting.executeScript` runs the injected function the way a browser does: from its
// source text in a fresh scope, so a function that reaches for a module import fails here as it would in a tab, with
// the page's globals set and its result structured-cloned.
import { createBrowserFacade } from '@extfn/core';

export function createFakeBrowser({ target = 'chromium-mv3', tabs = [], page, injectError, menuItems = [] } = {}) {
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
          // `null` reads everything, as in the browsers.
          if (key === null) return structuredClone(Object.fromEntries(local));
          return local.has(key) ? { [key]: structuredClone(local.get(key)) } : {};
        },
        async set(items) {
          record('storage.local.set', structuredClone(items));
          for (const [key, value] of Object.entries(items)) local.set(key, structuredClone(value));
        },
        async remove(keys) {
          record('storage.local.remove', keys);
          for (const key of [keys].flat()) local.delete(key);
        }
      },
      sync: { get: forbidden('storage.sync.get'), set: forbidden('storage.sync.set'), remove: forbidden('storage.sync.remove') }
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
        for (const origin of request.origins) granted.add(origin);
        return true;
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

/** A page for `executeScript`: `head` is the `<head>` outerHTML, or null for a document without one. */
export function fakePage({ url, title = '', head = '<head></head>', lang = '', contentType = 'text/html', selection = '' }) {
  return { url, title, head, lang, contentType, selection };
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
      head: page.head === null ? null : { outerHTML: page.head },
      title: page.title,
      documentElement: { lang: page.lang },
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
