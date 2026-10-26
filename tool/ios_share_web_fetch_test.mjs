import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

// 直接执行生产代码中的隔离世界脚本，固定网络响应验证恢复边界。
const source = readFileSync('ios/ShareExtension/ShareWebSession.swift', 'utf8');
const script = source.match(/let script = """\n([\s\S]*?)\n        """/)[1];
const execute = new (Object.getPrototypeOf(async () => {}).constructor)(
  'url', 'expectedOrigin', 'timeoutMilliseconds', 'maxBytes', 'binary', 'requestID', script,
);
const origin = 'https://linux.do';
globalThis.location = { origin };
let count = 0;
async function run({ body = '{"id":123}', status = 200, headers = {}, binary = false, max = 1024, fetcher } = {}) {
  globalThis.fetch = fetcher ?? (async (url, options) => {
    assert.equal(new URL(url).origin, origin);
    assert.equal(options.credentials, 'same-origin');
    assert.equal(options.redirect, 'manual');
    assert.equal(options.method, 'GET');
    assert.equal(options.headers.Cookie, undefined);
    return new Response(body, { status, headers });
  });
  const result = await execute(`${origin}/t/123.json`, origin, 30, max, binary, `${++count}`);
  assert.equal(globalThis.fluxdoShareRequests.size, 0);
  return result;
}

const challenge = await run({ body: '<html>challenge</html>', status: 403, headers: { 'cf-mitigated': 'challenge' } });
assert.equal(challenge.status, 403);
assert.equal(challenge.mitigated, 'challenge');
const recovered = await run();
assert.equal(recovered.ok, true);
assert.equal(JSON.parse(recovered.body).id, 123);
const bytes = Uint8Array.from([0, 127, 128, 255]);
const image = await run({ body: bytes, binary: true, headers: { 'content-type': 'image/png' } });
assert.deepEqual(Buffer.from(image.body, 'base64'), Buffer.from(bytes));
assert.equal(image.contentType, 'image/png');
assert.equal((await run({ body: 'too large', max: 2 })).reason, 'tooLarge');
assert.equal((await run({ fetcher: async () => ({ type: 'opaqueredirect' }) })).reason, 'redirect');
assert.equal((await run({ fetcher: async () => { throw new TypeError('network unavailable'); } })).reason, 'network');
assert.equal((await run({ fetcher: async (_, options) => new Promise((_, reject) => {
  options.signal.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')));
}) })).reason, 'timeout');
globalThis.location.origin = 'https://evil.example';
let requested = false;
assert.equal((await run({ fetcher: async () => { requested = true; } })).reason, 'origin');
assert.equal(requested, false);
console.log('通过：实际 WebKit fetch 脚本的挑战后恢复、同源 Cookie、跳转拒绝、图片字节、大小限制、超时和跨站页面隔离');
