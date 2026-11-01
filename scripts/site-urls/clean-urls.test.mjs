// node --test scripts/site-urls/clean-urls.test.mjs
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import vm from 'node:vm';

const context = {};
vm.runInNewContext(readFileSync(new URL('./clean-urls.js', import.meta.url), 'utf8'), context);

const run = (uri, querystring = {}) => context.handler({ request: { method: 'GET', uri, querystring, headers: {}, cookies: {} } });

function assertServes(uri, file) {
  const result = run(uri);
  assert.equal(result.statusCode, undefined, `${uri} should not redirect`);
  assert.equal(result.uri, file);
}

function assertRedirects(uri, location, querystring) {
  const result = run(uri, querystring);
  assert.equal(result.statusCode, 301, `${uri} should redirect`);
  assert.equal(result.headers.location.value, location);
}

test('clean addresses serve the page with that name', () => {
  for (const page of ['hub', 'mac', 'help', 'privacy', 'terms', 'licenses']) assertServes(`/${page}`, `/${page}.html`);
  assertServes('/help/hub', '/help/hub.html');
});

test('the home page is served as it is', () => assertServes('/', '/'));

test('old page addresses redirect to the clean ones', () => {
  for (const page of ['help', 'privacy', 'terms', 'licenses']) assertRedirects(`/${page}.html`, `/${page}`);
  assertRedirects('/index.html', '/');
  assertRedirects('/index', '/');
});

test('a trailing slash redirects', () => assertRedirects('/hub/', '/hub'));

test('redirects keep the query string', () => {
  assertRedirects('/help.html', '/help?a=1&b=two%20words', { a: { value: '1' }, b: { value: 'two%20words' } });
  assertRedirects('/help.html', '/help?a=1&a=2', { a: { value: '2', multiValue: [{ value: '1' }, { value: '2' }] } });
  assertRedirects('/index.html', '/?a=1', { a: { value: '1' } });
});

test('files shipped apps and other sites depend on are never touched', () => {
  for (const uri of [
    '/appcast.xml',
    '/assets/tour.mp4',
    '/assets/fonts/x.woff2',
    '/robots.txt',
    '/sitemap.xml',
    '/.well-known/security.txt',
    '/styles.css',
    '/download/Binders-0.14.0.dmg',
  ]) assertServes(uri, uri);
});

test('the error page stays an error', () => {
  assertServes('/404.html', '/404.html');
  assertServes('/404', '/404');
});

test('no address can redirect to another site', () => {
  for (const uri of ['//example.com/x.html', '//example.com/', '//example.com', '/\\example.com/x.html', '/%2F%2Fexample.com/x.html', '/help//x.html']) {
    assertServes(uri, uri);
  }
});
