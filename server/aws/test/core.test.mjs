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
  assert.deepEqual(check(idToken({})), { provider: 'google', sub: '1234', email: 'u@example.com', emailVerified: true, name: 'User' });
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

// ── Sign in with Apple ──
import { appleClientSecret, revokeAppleTokens, tokenProvider, verifyIdToken } from '../src/core.mjs';

function appleToken(claims) {
  const h = Buffer.from(JSON.stringify({ alg: 'RS256', kid: 'k1' })).toString('base64url');
  const p = Buffer.from(JSON.stringify({
    iss: 'https://appleid.apple.com', aud: 'com.vinylo.ios', sub: '001234.abcd', email: 'x@privaterelay.appleid.com',
    email_verified: 'true', iat: now / 1000, exp: now / 1000 + 600, ...claims,
  })).toString('base64url');
  return `${h}.${p}.${sign('sha256', Buffer.from(`${h}.${p}`), google.privateKey).toString('base64url')}`;
}

test('the issuer tells Google and Apple tokens apart', () => {
  assert.equal(tokenProvider(idToken({})), 'google');
  assert.equal(tokenProvider(appleToken({})), 'apple');
  assert.equal(tokenProvider(appleToken({ iss: 'https://evil.example.com' })), null);
});

test('an Apple identity token for the app gives an apple: user without a name', () => {
  const p = verifyIdToken(appleToken({}), { provider: 'apple', jwks, audiences: ['com.vinylo.ios'], now });
  assert.equal(p.provider, 'apple');
  assert.equal(p.name, null);
  assert.equal(userRecord(p).userId, 'apple:001234.abcd');
  assert.throws(() => verifyIdToken(appleToken({ aud: 'com.other.app' }), { provider: 'apple', jwks, audiences: ['com.vinylo.ios'], now }), /audience/);
  // A Google token cannot pass as an Apple one.
  assert.throws(() => verifyIdToken(idToken({ aud: 'com.vinylo.ios' }), { provider: 'apple', jwks, audiences: ['com.vinylo.ios'], now }), /issuer/);
});

test('Apple client secret: ES256, aud appleid.apple.com, sub = bundle ID', () => {
  const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
  const p8 = privateKey.export({ type: 'pkcs8', format: 'pem' });
  const jwt = appleClientSecret({ p8, teamId: 'TEAM', keyId: 'SIWAKEY', clientId: 'com.vinylo.ios', now });
  const [h, p] = jwt.split('.');
  assert.deepEqual(part(h), { alg: 'ES256', kid: 'SIWAKEY' });
  assert.equal(part(p).aud, 'https://appleid.apple.com');
  assert.equal(part(p).sub, 'com.vinylo.ios');
  assert.equal(part(p).iss, 'TEAM');
});

test('revocation exchanges the code, then revokes the refresh token', async () => {
  const calls = [];
  await revokeAppleTokens({
    code: 'c1', clientId: 'com.vinylo.ios', clientSecret: 's',
    post: async (url, form) => {
      calls.push([url, form]);
      return url.endsWith('/token') ? { status: 200, json: { refresh_token: 'r1' } } : { status: 200, json: {} };
    },
  });
  assert.equal(calls[0][0], 'https://appleid.apple.com/auth/token');
  assert.equal(calls[0][1].code, 'c1');
  assert.equal(calls[1][0], 'https://appleid.apple.com/auth/revoke');
  assert.deepEqual([calls[1][1].token, calls[1][1].token_type_hint], ['r1', 'refresh_token']);
  await assert.rejects(revokeAppleTokens({ code: 'bad', clientId: 'x', clientSecret: 's', post: async () => ({ status: 400, json: { error: 'invalid_grant' } }) }), /invalid_grant/);
});

import { coinDay, isSessionToken, InputError, sessionToken, songInput, verifySession, AuthError as AE } from '../src/core.mjs';

test('session tokens round-trip and refuse another secret or an old token', () => {
  const { token, expiresAt } = sessionToken({ secret: 's1', userId: 'google:1', now: 0 });
  assert.equal(expiresAt, 30 * 24 * 3600);
  assert.ok(isSessionToken(token));
  assert.equal(verifySession(token, { secret: 's1', now: 1000 }), 'google:1');
  assert.throws(() => verifySession(token, { secret: 's2', now: 1000 }), AE);
  assert.throws(() => verifySession(token, { secret: 's1', now: (expiresAt + 1) * 1000 }), AE);
});

test('the coin day turns at midnight in Seoul', () => {
  assert.equal(coinDay(Date.parse('2026-11-20T14:59:00Z')), '2026-11-20');
  assert.equal(coinDay(Date.parse('2026-11-20T15:00:00Z')), '2026-11-21');
});

test('song input keeps metadata and refuses lyrics', () => {
  assert.deepEqual(songInput({ title: ' A ', artist: 'B', isrc: 'usrc17607839' }), { title: 'A', artist: 'B', appleMusicId: null, isrc: 'USRC17607839', artworkUrl: null, addedAt: null });
  assert.throws(() => songInput({ title: 'A', artist: 'B', lines: [] }), InputError);
  assert.throws(() => songInput({ title: 'A' }), InputError);
});
