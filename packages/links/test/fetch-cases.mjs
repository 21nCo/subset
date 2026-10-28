// Fetcher cases shared by test/fetch.test.mjs (Node) and test/workerd.test.mjs (workerd). They use only web
// APIs and receive the package as `lib`, so the same file runs unchanged in both runtimes. Every case uses a
// fake fetch that serves only the URLs it lists and records each request: a request to any other URL, such
// as a blocked target, fails the case.

const encoder = new TextEncoder();

function fail(message) {
  throw new Error(message);
}

function equal(actual, expected, label) {
  const [a, e] = [JSON.stringify(actual), JSON.stringify(expected)];
  if (a !== e) fail(`${label}: expected ${e}, got ${a}`);
}

async function rejects(lib, promise, code, label) {
  try {
    await promise;
  } catch (error) {
    if (!(error instanceof lib.LinkFetchError)) fail(`${label}: expected a LinkFetchError, got ${error}`);
    equal(error.code, code, `${label} code`);
    return error;
  }
  return fail(`${label}: expected ${code}, but it resolved`);
}

/** A fake fetch serving `routes` (URL to response factory) and recording every request. */
function fakeFetch(routes) {
  const calls = [];
  const fetch = async (url, init) => {
    calls.push({ url, init });
    const route = routes[url];
    if (!route) fail(`unexpected request to ${url}`);
    return route(init);
  };
  return { fetch, calls, urls: () => calls.map((call) => call.url) };
}

const html = (body, headers = { 'content-type': 'text/html; charset=utf-8' }) => () => new Response(body, { headers });
const redirect = (location, status = 302, headers = {}) => () => new Response(null, { status, headers: { location, ...headers } });

/** A body stream that records how often it was read and whether it was cancelled. `next` returns each chunk or undefined to close. */
function trackedStream(next) {
  const state = { pulls: 0, cancelled: false };
  state.stream = new ReadableStream(
    {
      async pull(controller) {
        const chunk = await next(state.pulls++);
        if (chunk === undefined) controller.close();
        else controller.enqueue(typeof chunk === 'string' ? encoder.encode(chunk) : chunk);
      },
      cancel() {
        state.cancelled = true;
      }
    },
    { highWaterMark: 0 }
  );
  return state;
}

async function expectBlocked(lib, urls, code) {
  for (const url of urls) {
    const fake = fakeFetch({});
    await rejects(lib, lib.fetchLinkDetails(url, { fetch: fake.fetch }), code, url);
    equal(fake.urls(), [], `requests for ${url}`);
  }
}

async function expectAllowed(lib, urls, options = {}) {
  for (const url of urls) {
    const fake = fakeFetch({ [new URL(url).href]: html('<title>Public</title>') });
    const details = await lib.fetchLinkDetails(url, { fetch: fake.fetch, ...options });
    equal(details.title, 'Public', `title for ${url}`);
    equal(fake.urls(), [new URL(url).href], `requests for ${url}`);
  }
}

const never = () => new Promise(() => {});

export const cases = [
  {
    name: 'each blocked hostname pattern is rejected without a request',
    async run(lib) {
      await expectBlocked(
        lib,
        ['http://localhost/', 'http://LOCALHOST./admin', 'http://app.localhost/', 'http://printer.local/', 'http://db.internal/', 'http://nas.home.arpa/'],
        'blocked_address'
      );
      // Only those suffixes: lookalike names are public.
      await expectAllowed(lib, ['https://localhost.example.com/', 'https://local.example/', 'https://internal.example.com/', 'https://home.arpa.example/']);
    }
  },
  {
    name: 'each blocked IPv4 range is rejected, in every form the URL parser accepts',
    async run(lib) {
      await expectBlocked(
        lib,
        [
          'http://0.1.2.3/',
          'http://10.0.0.1/',
          'http://100.64.0.1/',
          'http://127.0.0.1/',
          'http://169.254.169.254/latest/meta-data/',
          'http://172.16.0.1/',
          'http://192.168.1.1/',
          'http://198.18.0.1/',
          'http://224.0.0.1/',
          'http://240.0.0.1/',
          'http://255.255.255.255/',
          // Decimal, hexadecimal and short forms normalize to 127.0.0.1 and 10.0.0.1.
          'http://2130706433/',
          'http://0x7f.1/',
          'http://10.1/'
        ],
        'blocked_address'
      );
      // The neighbours just outside each prefix are public.
      await expectAllowed(lib, [
        'http://1.0.0.1/',
        'http://11.0.0.1/',
        'http://100.63.255.255/',
        'http://100.128.0.1/',
        'http://126.255.255.255/',
        'http://169.253.0.1/',
        'http://172.15.255.255/',
        'http://172.32.0.1/',
        'http://192.167.1.1/',
        'http://198.20.0.1/',
        'http://223.255.255.255/'
      ]);
    }
  },
  {
    name: 'each blocked IPv6 form is rejected, including IPv4-mapped private addresses',
    async run(lib) {
      await expectBlocked(
        lib,
        ['http://[::]/', 'http://[::1]/', 'http://[fc00::1]/', 'http://[fdff:ffff::1]/', 'http://[fe80::1]/', 'http://[febf::1]/', 'http://[::ffff:127.0.0.1]/', 'http://[::ffff:a00:1]/', 'http://[::ffff:169.254.169.254]/'],
        'blocked_address'
      );
      await expectAllowed(lib, ['http://[2606:4700::1111]/', 'http://[::2]/', 'http://[fbff::1]/', 'http://[fec0::1]/', 'http://[::ffff:8.8.8.8]/']);
    }
  },
  {
    name: 'isBlockedAddress and isBlockedHostname expose the same rules, failing closed on malformed addresses',
    async run(lib) {
      equal(['10.0.0.1', '[::1]', '::ffff:7f00:1', 'fe80::1%eth0', '010.0.0.1', '1.2.3', '::1::', 'example.com'].map(lib.isBlockedAddress), [true, true, true, true, true, true, true, true], 'blocked');
      // A dotted IPv4 piece is valid only at the very end of an IPv6 address.
      equal(['127.0.0.1::', '10.0.0.1::', '8.8.8.8::1', '1:8.8.8.8::', '1:2:3:4:5:8.8.8.8:7'].map(lib.isBlockedAddress), [true, true, true, true, true], 'misplaced dotted piece');
      equal(['8.8.8.8', '2606:4700::1111', '::ffff:8.8.8.8', '1:2:3:4:5:6:7:8', '64:ff9b::8.8.8.8', '1:2:3:4:5:6:8.8.8.8'].map(lib.isBlockedAddress), [false, false, false, false, false, false], 'public');
      equal(['localhost', 'A.Local.', 'x.home.arpa', 'example.com', 'notlocal'].map(lib.isBlockedHostname), [true, true, true, false, false], 'hostnames');
    }
  },
  {
    name: 'only ports 80 and 443 are fetched unless allowPorts adds one',
    async run(lib) {
      await expectBlocked(lib, ['https://example.com:8443/', 'http://example.com:22/', 'http://example.com:0/'], 'blocked_port');
      await expectAllowed(lib, ['http://example.com:80/', 'https://example.com:443/', 'http://example.com:443/']);
      await expectAllowed(lib, ['https://example.com:8443/'], { allowPorts: [8443] });
      // A blocked address stays blocked on an allowed port.
      const fake = fakeFetch({});
      await rejects(lib, lib.fetchLinkDetails('http://127.0.0.1:8080/', { fetch: fake.fetch, allowPorts: [8080] }), 'blocked_address', 'loopback on an allowed port');
      equal(fake.urls(), [], 'requests');
    }
  },
  {
    name: 'invalid_url for input that is not an absolute http or https URL',
    async run(lib) {
      for (const input of ['not a url', '/relative', 'ftp://example.com/file', 'javascript:alert(1)', 'file:///etc/passwd', 42, undefined]) {
        const fake = fakeFetch({});
        const error = await rejects(lib, lib.fetchLinkDetails(input, { fetch: fake.fetch }), 'invalid_url', String(input));
        equal(error.url, undefined, `url of ${String(input)}`);
        equal(fake.urls(), [], `requests for ${String(input)}`);
      }
    }
  },
  {
    name: 'a public page redirecting to a private address is stopped before the private request',
    async run(lib) {
      for (const [location, code] of [
        ['http://169.254.169.254/latest/meta-data/', 'blocked_address'],
        ['http://localhost:3000/', 'blocked_address'],
        ['http://[::ffff:192.168.0.1]/', 'blocked_address'],
        ['https://example.org:6379/', 'blocked_port'],
        ['gopher://example.org/', 'invalid_url'],
        ['http://[::1', 'invalid_url']
      ]) {
        const fake = fakeFetch({ 'https://example.com/start': redirect(location) });
        const error = await rejects(lib, lib.fetchLinkDetails('https://example.com/start', { fetch: fake.fetch }), code, location);
        equal(fake.urls(), ['https://example.com/start'], `requests for ${location}`);
        equal(error.url, code === 'invalid_url' ? 'https://example.com/start' : new URL(location).href, `error url for ${location}`);
      }
    }
  },
  {
    name: 'redirects are followed manually, relative to the current hop, up to maxRedirects',
    async run(lib) {
      const fake = fakeFetch({
        'http://example.com/a': redirect('https://example.com/b', 301),
        'https://example.com/b': redirect('/c?x=1', 308),
        'https://example.com/c?x=1': html('<title>Final</title>')
      });
      const details = await lib.fetchLinkDetails('http://example.com/a', { fetch: fake.fetch });
      equal(details.url, 'https://example.com/c?x=1', 'final url');
      equal(details.title, 'Final', 'title');
      equal(fake.urls(), ['http://example.com/a', 'https://example.com/b', 'https://example.com/c?x=1'], 'requests');
      equal(fake.calls.map((call) => call.init.redirect), ['manual', 'manual', 'manual'], 'redirect mode');

      const chain = (length) => {
        const routes = {};
        for (let hop = 0; hop < length; hop++) routes[`https://example.com/${hop}`] = redirect(`/${hop + 1}`, 302 + (hop % 2) * 5);
        routes[`https://example.com/${length}`] = html('<title>End</title>');
        return fakeFetch(routes);
      };
      const five = chain(5);
      equal((await lib.fetchLinkDetails('https://example.com/0', { fetch: five.fetch })).title, 'End', 'five redirects');
      equal(five.urls().length, 6, 'requests for five redirects');
      const six = chain(6);
      await rejects(lib, lib.fetchLinkDetails('https://example.com/0', { fetch: six.fetch }), 'too_many_redirects', 'six redirects');
      equal(six.urls().length, 6, 'requests for six redirects');
      const none = chain(1);
      await rejects(lib, lib.fetchLinkDetails('https://example.com/0', { fetch: none.fetch, maxRedirects: 0 }), 'too_many_redirects', 'maxRedirects 0');
      equal(none.urls(), ['https://example.com/0'], 'requests with maxRedirects 0');
      const loop = fakeFetch({ 'https://example.com/loop': redirect('/loop') });
      await rejects(lib, lib.fetchLinkDetails('https://example.com/loop', { fetch: loop.fetch, maxRedirects: 2 }), 'too_many_redirects', 'loop');
      equal(loop.urls().length, 3, 'requests for a loop');
    }
  },
  {
    name: 'resolveHost: every resolved address of every hop is checked before the hop is requested',
    async run(lib) {
      const lookups = [];
      const resolveHost = (hostname) => {
        lookups.push(hostname);
        return { 'example.com': ['93.184.215.14', '2606:2800:21f:cb07:6820:80da:af6b:8b2c'], 'rebind.example': ['93.184.215.14', '10.0.0.5'], 'six.example': ['::1'], 'mapped.example': ['::ffff:127.0.0.1'], 'zone.example': ['fe80::1%en0'], 'junk.example': ['not-an-address'], 'dotted.example': ['127.0.0.1::'], 'hole.example': Array(1), 'gap.example': [, '93.184.215.14'], 'number.example': ['93.184.215.14', 167772161] }[hostname] ?? [];
      };
      // Malformed results fail closed: a hole or a non-string anywhere in the list blocks the hop.
      for (const hostname of ['rebind.example', 'six.example', 'mapped.example', 'zone.example', 'junk.example', 'dotted.example', 'hole.example', 'gap.example', 'number.example']) {
        const fake = fakeFetch({});
        await rejects(lib, lib.fetchLinkDetails(`https://${hostname}/`, { fetch: fake.fetch, resolveHost }), 'blocked_address', hostname);
        equal(fake.urls(), [], `requests for ${hostname}`);
      }
      // A redirect to a hostname resolving privately is stopped too.
      const fake = fakeFetch({ 'https://example.com/': redirect('https://rebind.example/admin') });
      await rejects(lib, lib.fetchLinkDetails('https://example.com/', { fetch: fake.fetch, resolveHost }), 'blocked_address', 'redirect to rebind.example');
      equal(fake.urls(), ['https://example.com/'], 'requests for the redirect');
      // A public resolution is fetched; an IP literal is not looked up.
      lookups.length = 0;
      await expectAllowed(lib, ['https://example.com/', 'https://93.184.215.14/'], { resolveHost });
      equal(lookups, ['example.com'], 'lookups');
      // Asynchronous resolvers work, and failures are network errors.
      await expectAllowed(lib, ['https://example.com/'], { resolveHost: async () => ['93.184.215.14'] });
      for (const [label, failing] of [
        ['no addresses', () => []],
        ['a thrown error', () => { throw new Error('ENOTFOUND'); }],
        ['a rejection', async () => { throw new Error('EAI_AGAIN'); }]
      ]) {
        const none = fakeFetch({});
        await rejects(lib, lib.fetchLinkDetails('https://example.com/', { fetch: none.fetch, resolveHost: failing }), 'network', label);
        equal(none.urls(), [], `requests after ${label}`);
      }
    }
  },
  {
    name: 'timeout covers resolution, the request and the body, whether or not they honour the abort signal',
    async run(lib) {
      const ignoring = fakeFetch({ 'https://example.com/': never });
      await rejects(lib, lib.fetchLinkDetails('https://example.com/', { fetch: ignoring.fetch, timeoutMs: 30 }), 'timeout', 'fetch ignoring the signal');
      let signal;
      const honouring = fakeFetch({
        'https://example.com/': (init) => {
          signal = init.signal;
          return new Promise((_, reject) => init.signal.addEventListener('abort', () => reject(new Error('aborted'))));
        }
      });
      const error = await rejects(lib, lib.fetchLinkDetails('https://example.com/', { fetch: honouring.fetch, timeoutMs: 30 }), 'timeout', 'fetch honouring the signal');
      equal(error.url, 'https://example.com/', 'timeout url');
      equal(signal.aborted, true, 'signal aborted');
      const slowLookup = fakeFetch({});
      await rejects(lib, lib.fetchLinkDetails('https://example.com/', { fetch: slowLookup.fetch, resolveHost: never, timeoutMs: 30 }), 'timeout', 'resolveHost');
      equal(slowLookup.urls(), [], 'requests after a slow lookup');
      const body = trackedStream((pull) => (pull === 0 ? '<title>Never fini' : never()));
      const stalled = fakeFetch({ 'https://example.com/': () => new Response(body.stream, { headers: { 'content-type': 'text/html' } }) });
      await rejects(lib, lib.fetchLinkDetails('https://example.com/', { fetch: stalled.fetch, timeoutMs: 50 }), 'timeout', 'stalled body');
      // The timer spans every hop rather than restarting per request.
      const hop = (next) => () => new Promise((resolve) => setTimeout(() => resolve(redirect(next)()), 20));
      const slowChain = fakeFetch({ 'https://example.com/1': hop('/2'), 'https://example.com/2': hop('/3'), 'https://example.com/3': hop('/4'), 'https://example.com/4': html('<title>Late</title>') });
      await rejects(lib, lib.fetchLinkDetails('https://example.com/1', { fetch: slowChain.fetch, timeoutMs: 50 }), 'timeout', 'slow chain');
    }
  },
  {
    name: 'the body is cut at maxBytes: details from the start, too_large only when the start has none',
    async run(lib) {
      const endless = trackedStream((pull) => (pull === 0 ? '<html lang="en"><title>Endless</title>' : '<p>more</p>'.repeat(100)));
      const fake = fakeFetch({ 'https://example.com/': () => new Response(endless.stream, { headers: { 'content-type': 'text/html' } }) });
      const details = await lib.fetchLinkDetails('https://example.com/', { fetch: fake.fetch, maxBytes: 4096 });
      equal([details.title, details.language], ['Endless', 'en'], 'details from the start');
      equal(endless.cancelled, true, 'stream cancelled');
      if (endless.pulls > 6) fail(`read ${endless.pulls} chunks for a 4,096 byte limit`);

      // A tag after the cut is not read.
      const late = `<title>Early</title>${' '.repeat(5000)}<meta name="description" content="Late">`;
      const cut = await lib.fetchLinkDetails('https://example.com/', { fetch: fakeFetch({ 'https://example.com/': html(late) }).fetch, maxBytes: 1000 });
      equal([cut.title, cut.description], ['Early', undefined], 'cut details');

      const junk = () => trackedStream(() => '<div>filler</div>'.repeat(64));
      const blank = junk();
      const tooLarge = fakeFetch({ 'https://example.com/': () => new Response(blank.stream, { headers: { 'content-type': 'text/html' } }) });
      const error = await rejects(lib, lib.fetchLinkDetails('https://example.com/', { fetch: tooLarge.fetch, maxBytes: 4096 }), 'too_large', 'nothing parseable');
      equal(error.url, 'https://example.com/', 'too_large url');
      equal(blank.cancelled, true, 'junk stream cancelled');
      // The same markup within the limit is a valid, empty record, not too_large.
      const small = await lib.fetchLinkDetails('https://example.com/', { fetch: fakeFetch({ 'https://example.com/': html('<div>filler</div>'.repeat(10)) }).fetch, maxBytes: 4096 });
      equal(small, { version: 1, url: 'https://example.com/', icons: [{ url: 'https://example.com/favicon.ico', rel: 'icon' }], contentType: 'text/html' }, 'small record');
      // A body filling maxBytes counts as cut: no further read can tell it from a larger one.
      const exact = '<div>filler</div>'.repeat(4);
      await rejects(lib, lib.fetchLinkDetails('https://example.com/', { fetch: fakeFetch({ 'https://example.com/': html(exact) }).fetch, maxBytes: encoder.encode(exact).length }), 'too_large', 'exact-size blank');
    }
  },
  {
    name: 'a body filling maxBytes is parsed without waiting for another read',
    async run(lib) {
      const prefix = '<title>Ready</title>';
      const stalled = trackedStream((pull) => (pull === 0 ? prefix : never()));
      const fake = fakeFetch({ 'https://example.com/': () => new Response(stalled.stream, { headers: { 'content-type': 'text/html' } }) });
      const details = await lib.fetchLinkDetails('https://example.com/', { fetch: fake.fetch, maxBytes: encoder.encode(prefix).length, timeoutMs: 1000 });
      equal(details.title, 'Ready', 'title from a body filling maxBytes');
      equal([stalled.pulls, stalled.cancelled], [1, true], 'one read, then cancelled');
    }
  },
  {
    name: 'a response arriving after the timeout is cancelled unread',
    async run(lib) {
      for (const [label, operation] of [
        ['fetchLinkDetails', lib.fetchLinkDetails],
        ['fetchResource', lib.fetchResource]
      ]) {
        const body = trackedStream(() => '<title>Late</title>');
        let deliver;
        // A fetch that ignores the abort signal and answers only once the test delivers its response.
        const late = fakeFetch({
          'https://example.com/': () => new Promise((resolve) => (deliver = () => resolve(new Response(body.stream, { headers: { 'content-type': 'text/html' } }))))
        });
        let forced = false;
        const fallback = setTimeout(() => {
          forced = true;
          deliver();
        }, 2000);
        await rejects(lib, operation('https://example.com/', { fetch: late.fetch, timeoutMs: 15 }), 'timeout', label);
        clearTimeout(fallback);
        if (forced) fail(`${label}: the timeout waited for the late response`);
        deliver();
        await new Promise((resolve) => setTimeout(resolve, 0));
        equal([body.pulls, body.cancelled], [0, true], `${label}: late body cancelled unread`);
      }
    }
  },
  {
    name: 'HTML types are parsed; other types return the file name as title without reading the body',
    async run(lib) {
      const page = '<title>Typed</title><meta property="og:site_name" content="Site">';
      for (const contentType of ['text/html', 'TEXT/HTML; charset=utf-8', 'application/xhtml+xml', undefined, 'not a type']) {
        const headers = contentType ? { 'content-type': contentType } : {};
        const fake = fakeFetch({ 'https://example.com/p': () => new Response(encoder.encode(page), { headers }) });
        const details = await lib.fetchLinkDetails('https://example.com/p', { fetch: fake.fetch });
        equal([details.title, details.siteName], ['Typed', 'Site'], `details for ${contentType}`);
        // A missing or malformed header means HTML, as in parseLinkDetails.
        equal(details.contentType, contentType === 'application/xhtml+xml' ? 'application/xhtml+xml' : 'text/html', `contentType for ${contentType}`);
      }
      for (const [path, contentType, expected] of [
        ['/files/Annual%20report%202025.pdf', 'application/pdf', { version: 1, url: 'https://example.com/files/Annual%20report%202025.pdf', title: 'Annual report 2025.pdf', icons: [{ url: 'https://example.com/favicon.ico', rel: 'icon' }], contentType: 'application/pdf' }],
        ['/img/cat.png?size=large', 'image/png', { version: 1, url: 'https://example.com/img/cat.png?size=large', title: 'cat.png', icons: [{ url: 'https://example.com/favicon.ico', rel: 'icon' }], contentType: 'image/png' }],
        ['/feed/', 'application/rss+xml; charset=utf-8', { version: 1, url: 'https://example.com/feed/', icons: [{ url: 'https://example.com/favicon.ico', rel: 'icon' }], contentType: 'application/rss+xml' }],
        ['/bad%E0%A4%A.txt', 'text/plain', { version: 1, url: 'https://example.com/bad%E0%A4%A.txt', title: 'bad%E0%A4%A.txt', icons: [{ url: 'https://example.com/favicon.ico', rel: 'icon' }], contentType: 'text/plain' }]
      ]) {
        const body = trackedStream(() => '<title>Not read</title>');
        const fake = fakeFetch({ [`https://example.com${path}`]: () => new Response(body.stream, { headers: { 'content-type': contentType } }) });
        const details = await lib.fetchLinkDetails(`https://example.com${path}`, { fetch: fake.fetch });
        equal(details, expected, `record for ${contentType}`);
        if (!lib.isLinkDetailsV1(details)) fail(`record for ${contentType} is not LinkDetailsV1`);
        equal([body.pulls, body.cancelled], [0, true], `body of ${contentType} released unread`);
      }
    }
  },
  {
    name: 'charset comes from the header, then the meta tag, then UTF-8',
    async run(lib) {
      const latin = (prefix, byte, suffix) => Uint8Array.from([...encoder.encode(prefix), byte, ...encoder.encode(suffix)]);
      const cases = [
        ['header', latin('<title>Caf', 0xe9, '</title>'), 'text/html; charset=iso-8859-1', 'Café'],
        ['meta', Uint8Array.from([...encoder.encode('<meta charset="windows-1251"><title>'), 0xcf, 0xf0, 0xe8, 0xe2, 0xe5, 0xf2, ...encoder.encode('</title>')]), 'text/html', 'Привет'],
        ['header over meta', latin('<meta charset="windows-1251"><title>Caf', 0xe9, '</title>'), 'text/html; charset=iso-8859-1', 'Café'],
        ['UTF-8 default', encoder.encode('<title>Café ✓</title>'), 'text/html', 'Café ✓']
      ];
      for (const [label, bytes, contentType, title] of cases) {
        const fake = fakeFetch({ 'https://example.com/': () => new Response(bytes, { headers: { 'content-type': contentType } }) });
        equal((await lib.fetchLinkDetails('https://example.com/', { fetch: fake.fetch })).title, title, label);
      }
    }
  },
  {
    name: 'http_status carries the status of a non-2xx final response',
    async run(lib) {
      for (const status of [404, 410, 500, 503, 304, 300]) {
        const body = trackedStream(() => 'error page');
        const fake = fakeFetch({ 'https://example.com/': () => new Response(status === 304 ? null : body.stream, { status }) });
        const error = await rejects(lib, lib.fetchLinkDetails('https://example.com/', { fetch: fake.fetch }), 'http_status', String(status));
        equal([error.status, error.url], [status, 'https://example.com/'], `status ${status}`);
      }
      // A redirect status without Location is a final response.
      const bare = fakeFetch({ 'https://example.com/': () => new Response(null, { status: 302 }) });
      equal((await rejects(lib, lib.fetchLinkDetails('https://example.com/', { fetch: bare.fetch }), 'http_status', '302 without Location')).status, 302, 'bare 302');
    }
  },
  {
    name: 'network for a failed request, body or hidden redirect',
    async run(lib) {
      const thrown = fakeFetch({ 'https://example.com/': () => { throw new TypeError('fetch failed'); } });
      const error = await rejects(lib, lib.fetchLinkDetails('https://example.com/', { fetch: thrown.fetch }), 'network', 'fetch throws');
      equal(error.url, 'https://example.com/', 'network url');
      const broken = new ReadableStream({ start(controller) { controller.enqueue(encoder.encode('<title>')); controller.error(new Error('reset')); } });
      const reset = fakeFetch({ 'https://example.com/': () => new Response(broken, { headers: { 'content-type': 'text/html' } }) });
      await rejects(lib, lib.fetchLinkDetails('https://example.com/', { fetch: reset.fetch }), 'network', 'body error');
      // What a browser's fetch returns for redirect: 'manual'.
      const opaque = fakeFetch({ 'https://example.com/': () => ({ type: 'opaqueredirect', status: 0, headers: new Headers(), body: null }) });
      await rejects(lib, lib.fetchLinkDetails('https://example.com/', { fetch: opaque.fetch }), 'network', 'opaque redirect');
    }
  },
  {
    name: 'requests carry the user agent and no cookies or credentials',
    async run(lib) {
      const fake = fakeFetch({
        'https://example.com/private': redirect('https://user2:secret2@example.org/next', 302, { 'set-cookie': 'session=1' }),
        'https://example.org/next': html('<title>Next</title>')
      });
      const details = await lib.fetchLinkDetails('https://user:pass@example.com/private', { fetch: fake.fetch });
      equal(details.url, 'https://example.org/next', 'final url without credentials');
      equal(fake.urls(), ['https://example.com/private', 'https://example.org/next'], 'requests without credentials');
      for (const { init } of fake.calls) {
        const headers = new Headers(init.headers);
        equal([...headers.keys()].sort(), ['accept', 'user-agent'], 'header names');
        equal(headers.get('user-agent'), lib.DEFAULT_USER_AGENT, 'user agent');
        equal([init.method, init.credentials, init.redirect], ['GET', 'omit', 'manual'], 'request mode');
      }
      if (!/^SubsetLinks\/\d+\.\d+\.\d+ \(\+https:\/\/subset\.dev\)$/.test(lib.DEFAULT_USER_AGENT)) fail(`default user agent ${lib.DEFAULT_USER_AGENT}`);
      const custom = fakeFetch({ 'https://example.com/': html('<title>x</title>') });
      await lib.fetchLinkDetails('https://example.com/', { fetch: custom.fetch, userAgent: 'Memotron/2' });
      equal(new Headers(custom.calls[0].init.headers).get('user-agent'), 'Memotron/2', 'custom user agent');
    }
  },
  {
    name: 'an injected fetch is called without a receiver, as a runtime fetch requires',
    async run(lib) {
      // A runtime's own fetch (workerd, browsers) throws "Illegal invocation" when called on another object.
      const urls = [];
      function strictFetch(url) {
        if (this !== undefined && this !== globalThis) throw new TypeError('Illegal invocation');
        urls.push(url);
        if (url === 'https://example.com/') return Promise.resolve(redirect('https://example.com/page')());
        if (url === 'https://example.com/page') return Promise.resolve(html('<title>Unbound</title>')());
        return Promise.resolve(new Response(Uint8Array.from([1, 2]), { headers: { 'content-type': 'image/png' } }));
      }
      equal((await lib.fetchLinkDetails('https://example.com/', { fetch: strictFetch })).title, 'Unbound', 'fetchLinkDetails title');
      equal((await lib.fetchResource('https://example.com/icon.png', { fetch: strictFetch })).contentType, 'image/png', 'fetchResource type');
      equal(urls, ['https://example.com/', 'https://example.com/page', 'https://example.com/icon.png'], 'requests');
    }
  },
  {
    name: 'fetchResource returns accepted bytes and applies the same target checks',
    async run(lib) {
      const png = Uint8Array.from([0x89, 0x50, 0x4e, 0x47, 1, 2, 3]);
      const fake = fakeFetch({
        'https://example.com/favicon': redirect('https://cdn.example.com/icon.png', 301),
        'https://cdn.example.com/icon.png': () => new Response(png, { headers: { 'content-type': 'image/png' } })
      });
      const resource = await lib.fetchResource('https://example.com/favicon', { fetch: fake.fetch, accept: ['image/png', 'image/*'], maxBytes: 256 * 1024 });
      equal([resource.url, resource.contentType, [...resource.bytes]], ['https://cdn.example.com/icon.png', 'image/png', [...png]], 'resource');
      equal(new Headers(fake.calls[0].init.headers).get('accept'), 'image/png, image/*', 'accept header');

      const blocked = fakeFetch({ 'https://example.com/favicon': redirect('http://127.0.0.1/icon.png') });
      await rejects(lib, lib.fetchResource('https://example.com/favicon', { fetch: blocked.fetch }), 'blocked_address', 'private icon');
      equal(blocked.urls(), ['https://example.com/favicon'], 'requests for a private icon');

      const unread = trackedStream(() => '<html>');
      const wrongType = fakeFetch({ 'https://example.com/i': () => new Response(unread.stream, { headers: { 'content-type': 'text/html' } }) });
      await rejects(lib, lib.fetchResource('https://example.com/i', { fetch: wrongType.fetch, accept: ['image/*'] }), 'unsupported_type', 'html for an image');
      equal([unread.pulls, unread.cancelled], [0, true], 'unaccepted body unread');
      const untyped = fakeFetch({ 'https://example.com/i': () => new Response(png) });
      await rejects(lib, lib.fetchResource('https://example.com/i', { fetch: untyped.fetch, accept: ['image/*'] }), 'unsupported_type', 'no content type');
      equal((await lib.fetchResource('https://example.com/i', { fetch: fakeFetch({ 'https://example.com/i': () => new Response(png) }).fetch })).contentType, 'application/octet-stream', 'any type by default');

      const declared = trackedStream(() => png);
      const big = fakeFetch({ 'https://example.com/i': () => new Response(declared.stream, { headers: { 'content-type': 'image/png', 'content-length': '999999' } }) });
      await rejects(lib, lib.fetchResource('https://example.com/i', { fetch: big.fetch, maxBytes: 1024 }), 'too_large', 'declared length');
      equal(declared.pulls, 0, 'declared too large: body unread');
      const endless = trackedStream(() => png);
      const streamed = fakeFetch({ 'https://example.com/i': () => new Response(endless.stream, { headers: { 'content-type': 'image/png' } }) });
      await rejects(lib, lib.fetchResource('https://example.com/i', { fetch: streamed.fetch, maxBytes: 64 }), 'too_large', 'streamed past maxBytes');
      equal(endless.cancelled, true, 'endless icon cancelled');
      const exact = await lib.fetchResource('https://example.com/i', { fetch: fakeFetch({ 'https://example.com/i': () => new Response(png, { headers: { 'content-type': 'image/png' } }) }).fetch, maxBytes: png.length });
      equal(exact.bytes.length, png.length, 'exactly maxBytes');
    }
  },
  {
    name: 'invalid options are rejected before any request',
    async run(lib) {
      const fake = fakeFetch({});
      for (const [label, options, type] of [
        ['timeoutMs 0', { timeoutMs: 0 }, RangeError],
        ['timeoutMs NaN', { timeoutMs: Number.NaN }, RangeError],
        // setTimeout would fire at once for a longer delay.
        ['timeoutMs 2**31', { timeoutMs: 2 ** 31 }, RangeError],
        ['maxBytes 0', { maxBytes: 0 }, RangeError],
        ['maxRedirects -1', { maxRedirects: -1 }, RangeError],
        ['allowPorts 70000', { allowPorts: [70000] }, RangeError],
        ['userAgent empty', { userAgent: ' ' }, TypeError],
        ['resolveHost not a function', { resolveHost: ['1.1.1.1'] }, TypeError]
      ]) {
        let error;
        try {
          await lib.fetchLinkDetails('https://example.com/', { fetch: fake.fetch, ...options });
        } catch (caught) {
          error = caught;
        }
        if (!(error instanceof type)) fail(`${label}: expected ${type.name}, got ${error}`);
      }
      for (const accept of [[], ['image'], ['*/png']]) {
        let error;
        try {
          await lib.fetchResource('https://example.com/', { fetch: fake.fetch, accept });
        } catch (caught) {
          error = caught;
        }
        if (!(error instanceof TypeError)) fail(`accept ${JSON.stringify(accept)}: expected TypeError, got ${error}`);
      }
      equal(fake.urls(), [], 'requests');
      const longest = fakeFetch({ 'https://example.com/': html('<title>Patient</title>') });
      equal((await lib.fetchLinkDetails('https://example.com/', { fetch: longest.fetch, timeoutMs: 2 ** 31 - 1 })).title, 'Patient', 'timeoutMs 2**31 - 1');
    }
  }
];
