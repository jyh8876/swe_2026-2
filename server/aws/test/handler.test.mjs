// Runs the Lambda handler end to end with stand-ins for DynamoDB, SSM and the network.
import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import { register } from 'node:module';
import { generateKeyPairSync, sign } from 'node:crypto';

register('./stubs/hooks.mjs', import.meta.url);

const rsa = generateKeyPairSync('rsa', { modulusLength: 2048 });
const jwk = { ...rsa.publicKey.export({ format: 'jwk' }), kid: 'k1', alg: 'RS256' };
const siwa = generateKeyPairSync('ec', { namedCurve: 'P-256' }).privateKey.export({ type: 'pkcs8', format: 'pem' });
const nowS = Math.floor(Date.now() / 1000);
function token(claims) {
  const h = Buffer.from(JSON.stringify({ alg: 'RS256', kid: 'k1' })).toString('base64url');
  const p = Buffer.from(JSON.stringify({ iat: nowS, exp: nowS + 600, ...claims })).toString('base64url');
  return `${h}.${p}.${sign('sha256', Buffer.from(`${h}.${p}`), rsa.privateKey).toString('base64url')}`;
}
const apple = (c = {}) => token({ iss: 'https://appleid.apple.com', aud: 'com.vinylo.ios', sub: 'a1', email: 'r@privaterelay.appleid.com', ...c });
const google = (c = {}) => token({ iss: 'https://accounts.google.com', aud: 'web-client', sub: 'g1', email: 'u@example.com', name: 'U', ...c });

let handler, table, appleCalls;
before(async () => {
  Object.assign(process.env, {
    USERS_TABLE: 'users', TEAM_ID: 'TEAM', GOOGLE_CLIENT_IDS: 'web-client', APPLE_CLIENT_IDS: 'com.vinylo.ios',
    SIWA_KEY_ID: 'SIWA1', SIWA_P8_PARAM: '/vinylo/siwa-p8',
  });
  appleCalls = [];
  globalThis.fetch = async (url, init) => {
    url = `${url}`;
    if (url.endsWith('/certs') || url.endsWith('/auth/keys')) return new Response(JSON.stringify({ keys: [jwk] }), { headers: { 'cache-control': 'max-age=60' } });
    appleCalls.push([url, Object.fromEntries(new URLSearchParams(init.body))]);
    return new Response(JSON.stringify(url.endsWith('/auth/token') ? { refresh_token: 'rt' } : {}), { status: 200 });
  };
  (await import('./stubs/ssm.mjs')).params.set('/vinylo/siwa-p8', siwa);
  table = (await import('./stubs/dynamodb.mjs')).table;
  ({ handler } = await import('../src/index.mjs'));
});

const call = (method, path, { tok, body } = {}) => handler({
  requestContext: { http: { method } }, rawPath: path,
  headers: tok ? { authorization: `Bearer ${tok}` } : {}, body: body ? JSON.stringify(body) : undefined,
});

test('Apple sign-in keeps the name sent on the first sign-in and does not lose it later', async () => {
  let r = await call('POST', '/v1/me', { tok: apple(), body: { name: 'Kim' } });
  assert.equal(r.statusCode, 200);
  assert.deepEqual(JSON.parse(r.body).name, 'Kim');
  r = await call('POST', '/v1/me', { tok: apple({ email: undefined }) });
  const u = JSON.parse(r.body);
  assert.equal(u.userId, 'apple:a1');
  assert.equal(u.name, 'Kim');
  assert.equal(u.email, 'r@privaterelay.appleid.com');
  assert.deepEqual(Object.keys(u).sort(), ['createdAt', 'email', 'lastSeenAt', 'name', 'provider', 'userId']);
});

test('Google sign-in works next to Apple; bad tokens are refused', async () => {
  assert.equal(JSON.parse((await call('POST', '/v1/me', { tok: google() })).body).userId, 'google:g1');
  assert.equal((await call('POST', '/v1/me', { tok: apple({ aud: 'com.other' }) })).statusCode, 401);
  assert.equal((await call('POST', '/v1/me')).statusCode, 401);
  assert.equal((await call('GET', '/v1/me', { tok: google() })).statusCode, 200);
});

test('deleting an Apple account revokes the Apple tokens and removes the record', async () => {
  const r = await call('DELETE', '/v1/me', { tok: apple(), body: { authorizationCode: 'code1' } });
  assert.equal(r.statusCode, 200);
  assert.deepEqual(JSON.parse(r.body), { deleted: true, appleTokensRevoked: true });
  assert.equal(table.has('apple:a1'), false);
  assert.deepEqual(appleCalls.map(([u]) => u), ['https://appleid.apple.com/auth/token', 'https://appleid.apple.com/auth/revoke']);
  assert.equal(appleCalls[0][1].code, 'code1');
  assert.equal(appleCalls[1][1].token, 'rt');
  assert.equal((await call('GET', '/v1/me', { tok: apple() })).statusCode, 404);
});

test('health and unknown paths', async () => {
  assert.equal((await call('GET', '/health')).statusCode, 200);
  assert.equal((await call('GET', '/nope')).statusCode, 404);
});
