import { test } from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, sign, verify } from 'node:crypto';
import { appleMusicToken, MAX_TOKEN_SECONDS, TokenCache, verifyGoogleIdToken, userRecord, JwksCache } from '../src/core.mjs';

const part = (s) => JSON.parse(Buffer.from(s, 'base64url'));

test('Apple Music token: ES256 with kid, iss = Team ID, verifiable with the public key', () => {
  const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
  const p8 = privateKey.export({ type: 'pkcs8', format: 'pem' });
  const now = Date.UTC(2026, 10, 18);
  const { token, expiresAt } = appleMusicToken({ p8, teamId: 'TEAM123456', keyId: 'KEY1234567', now });
  const [h, p, sig] = token.split('.');
  assert.deepEqual(part(h), { alg: 'ES256', kid: 'KEY1234567' });
  assert.equal(part(p).iss, 'TEAM123456');
  assert.equal(part(p).iat, now / 1000);
  assert.equal(part(p).exp, expiresAt);
  assert.equal(Buffer.from(sig, 'base64url').length, 64); // raw r||s, as JWT requires
  assert.ok(verify('sha256', Buffer.from(`${h}.${p}`), { key: publicKey, dsaEncoding: 'ieee-p1363' }, Buffer.from(sig, 'base64url')));
});

test('Apple Music token never lives longer than 6 months', () => {
  const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
  const p8 = privateKey.export({ type: 'pkcs8', format: 'pem' });
  const { expiresAt } = appleMusicToken({ p8, teamId: 'T', keyId: 'K', now: 0, ttlSeconds: 10 ** 9 });
  assert.equal(expiresAt, MAX_TOKEN_SECONDS);
});

test('token cache re-issues only when the token is about to expire', () => {
  let made = 0;
  const cache = new TokenCache((now) => ({ n: ++made, expiresAt: now / 1000 + 30 * 86400 }), 7 * 86400);
  const a = cache.get(0);
  assert.equal(cache.get(20 * 86400 * 1000), a);
  assert.notEqual(cache.get(24 * 86400 * 1000), a);
  assert.equal(made, 2);
});

// A fake Google key pair to sign test ID tokens.
const google = generateKeyPairSync('rsa', { modulusLength: 2048 });
const jwks = { keys: [{ ...google.publicKey.export({ format: 'jwk' }), kid: 'k1', alg: 'RS256', use: 'sig' }] };
const now = Date.UTC(2026, 10, 18);
function idToken(claims, { kid = 'k1', key = google.privateKey } = {}) {
  const h = Buffer.from(JSON.stringify({ alg: 'RS256', kid })).toString('base64url');
  const p = Buffer.from(JSON.stringify({
    iss: 'https://accounts.google.com', aud: 'web-client', sub: '1234', email: 'u@example.com', email_verified: true,
    name: 'User', iat: now / 1000, exp: now / 1000 + 3600, ...claims,
  })).toString('base64url');
  return `${h}.${p}.${sign('sha256', Buffer.from(`${h}.${p}`), key).toString('base64url')}`;
}
const check = (t) => verifyGoogleIdToken(t, { jwks, audiences: ['web-client'], now });

test('a valid Google ID token gives the profile', () => {
  assert.deepEqual(check(idToken({})), { sub: '1234', email: 'u@example.com', emailVerified: true, name: 'User' });
});

test('Google ID tokens are rejected for the wrong audience, issuer, expiry, key or signature', () => {
  assert.throws(() => check(idToken({ aud: 'someone-else' })), /audience/);
  assert.throws(() => check(idToken({ iss: 'evil.example.com' })), /issuer/);
  assert.throws(() => check(idToken({ exp: now / 1000 - 3600 })), /expired/);
  assert.throws(() => check(idToken({}, { kid: 'k2' })), /unknown key/);
  const other = generateKeyPairSync('rsa', { modulusLength: 2048 }).privateKey;
  assert.throws(() => check(idToken({}, { key: other })), /signature/);
  assert.throws(() => check('not-a-token'), /malformed/);
});

test('the user record holds only id, provider, email, name and time', () => {
  const r = userRecord({ sub: '1234', email: 'u@example.com', name: 'User' }, new Date(now));
  assert.deepEqual(Object.keys(r).sort(), ['email', 'lastSeenAt', 'name', 'provider', 'userId']);
  assert.equal(r.userId, 'google:1234');
});

test('Google keys are fetched again only after max-age', async () => {
  let fetched = 0;
  const cache = new JwksCache(async () => ({ keys: { n: ++fetched }, maxAgeSeconds: 60 }));
  await cache.get(0);
  await cache.get(59_000);
  await cache.get(61_000);
  assert.equal(fetched, 2);
});
