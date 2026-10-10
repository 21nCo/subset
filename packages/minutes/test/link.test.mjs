import assert from 'node:assert/strict';
import { test } from 'node:test';
import { parseMeetingLink, redactUrl, redactUrlsInText } from '../dist/index.js';

test('accepts Google Meet codes and lookup links', () => {
  const result = parseMeetingLink('  https://meet.google.com/abc-defg-hij?authuser=1  ');
  assert.equal(result.ok, true);
  assert.equal(result.link.platform, 'google-meet');
  assert.equal(result.link.joinUrl, 'https://meet.google.com/abc-defg-hij?authuser=1');
  assert.equal(result.link.redacted, 'https://meet.google.com/abc-defg-hij');
  assert.equal(parseMeetingLink('https://meet.google.com/lookup/team-standup').ok, true);
});

test('maps Zoom join links to the web client and redacts the passcode', () => {
  for (const raw of [
    'https://zoom.us/j/1234567890?pwd=secret',
    'https://us02web.zoom.us/j/1234567890?pwd=secret',
    'https://us02web.zoom.us/s/1234567890?pwd=secret',
    'https://app.zoom.us/wc/join/1234567890?pwd=secret',
    'https://app.zoom.us/wc/1234567890/join?pwd=secret',
  ]) {
    const result = parseMeetingLink(raw);
    assert.equal(result.ok, true, raw);
    assert.equal(result.link.platform, 'zoom');
    assert.match(result.link.joinUrl, /\/wc\/join\/1234567890\?pwd=secret$/);
    assert.equal(result.link.redacted.includes('secret'), false);
    assert.equal(result.link.redacted.includes('?'), false);
  }
});

test('rejects anything that is not an https Meet or Zoom meeting link', () => {
  const rejected = [
    '',
    'not a url',
    'http://meet.google.com/abc-defg-hij',
    'https://meet.google.com/',
    'https://meet.google.com/landing',
    'https://meet.google.com.evil.example/abc-defg-hij',
    'https://evilzoom.us/j/1234567890',
    'https://zoom.us.evil.example/j/1234567890',
    'https://zoom.us/',
    'https://zoom.us/j/abc',
    'https://user:pass@meet.google.com/abc-defg-hij',
    'https://meet.google.com:8443/abc-defg-hij',
    'javascript:alert(1)',
    'file:///etc/passwd',
    `https://meet.google.com/abc-defg-hij?${'x'.repeat(3000)}`,
  ];
  for (const raw of rejected) {
    const result = parseMeetingLink(raw);
    assert.equal(result.ok, false, raw);
    assert.equal(typeof result.message, 'string');
  }
  assert.equal(parseMeetingLink(undefined).ok, false);
});

test('redactUrl drops query and fragment', () => {
  assert.equal(redactUrl('https://zoom.us/j/1?pwd=x#y'), 'https://zoom.us/j/1');
  assert.equal(redactUrl('nope'), '(unparsed link)');
  assert.equal(redactUrl('zoommtg://zoom.us/join?confno=1&pwd=x'), '(unparsed link)');
  assert.equal(
    redactUrlsInText('page.goto: net::ERR_ABORTED at https://zoom.us/wc/join/1234567890?pwd=secret\nCall log: navigating to "https://zoom.us/wc/join/1234567890?pwd=secret"'),
    'page.goto: net::ERR_ABORTED at https://zoom.us/wc/join/1234567890\nCall log: navigating to "https://zoom.us/wc/join/1234567890"',
  );
});
