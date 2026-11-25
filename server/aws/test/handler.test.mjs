// Runs the Lambda handler end to end with stand-ins for DynamoDB, SSM and the network.
import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import { register } from 'node:module';
import { generateKeyPairSync, sign } from 'node:crypto';

register('./stubs/hooks.mjs', import.meta.url);

const rsa = generateKeyPairSync('rsa', { modulusLength: 2048 });
const jwk = { ...rsa.publicKey.export({ format: 'jwk' }), kid: 'k1', alg: 'RS256' };
const siwa = generateKeyPairSync('ec', { namedCurve: 'P-256' }).privateKey.export({ type: 'pkcs8', format: 'pem' });
const playKey = generateKeyPairSync('rsa', { modulusLength: 2048 }).privateKey.export({ type: 'pkcs8', format: 'pem' });
const nowS = Math.floor(Date.now() / 1000);
function idToken(claims) {
  const h = Buffer.from(JSON.stringify({ alg: 'RS256', kid: 'k1' })).toString('base64url');
  const p = Buffer.from(JSON.stringify({ iat: nowS, exp: nowS + 600, ...claims })).toString('base64url');
  return `${h}.${p}.${sign('sha256', Buffer.from(`${h}.${p}`), rsa.privateKey).toString('base64url')}`;
}
const apple = (c = {}) => idToken({ iss: 'https://appleid.apple.com', aud: 'com.vinylo.ios', sub: 'a1', email: 'r@privaterelay.appleid.com', ...c });
const google = (c = {}) => idToken({ iss: 'https://accounts.google.com', aud: 'web-client', sub: 'g1', email: 'u@example.com', name: 'U', ...c });

// What the fake Google Play returns per purchase token.
const play = new Map();
let handler, table, calls;
before(async () => {
  Object.assign(process.env, {
    DATA_TABLE: 'data', TEAM_ID: 'TEAM', GOOGLE_CLIENT_IDS: 'web-client', APPLE_CLIENT_IDS: 'com.vinylo.ios',
    SIWA_KEY_ID: 'SIWA1', SIWA_P8_PARAM: '/vinylo/siwa-p8', SESSION_SECRET_PARAM: '/vinylo/session-secret',
    PLAY_PACKAGE: 'com.vinylo.app', PLAY_SA_PARAM: '/vinylo/play-sa',
    COIN_PRODUCTS: 'coins_10:10', UNLIMITED_PRODUCTS: 'unlimited_forever', UNLIMITED_SUBSCRIPTIONS: 'unlimited_monthly',
  });
  calls = [];
  globalThis.fetch = async (url, init = {}) => {
    url = `${url}`;
    calls.push([init.method ?? 'GET', url, init.body]);
    const json = (b, status = 200, headers = {}) => new Response(JSON.stringify(b), { status, headers });
    if (url.endsWith('/certs') || url.endsWith('/auth/keys')) return json({ keys: [jwk] }, 200, { 'cache-control': 'max-age=60' });
    if (url.endsWith('/auth/token')) return json({ refresh_token: 'rt' });
    if (url.endsWith('/auth/revoke')) return json({});
    if (url === 'https://oauth2.googleapis.com/token') return json({ access_token: 'play-at', expires_in: 3600 });
    if (url.includes('androidpublisher')) {
      if (url.endsWith(':acknowledge')) return json({});
      const token = decodeURIComponent(url.split('/tokens/')[1]);
      return play.has(token) ? json(play.get(token)) : json({ error: 'not found' }, 404);
    }
    throw new Error(`unexpected fetch ${url}`);
  };
  const { params } = await import('./stubs/ssm.mjs');
  params.set('/vinylo/siwa-p8', siwa);
  params.set('/vinylo/session-secret', 'test-session-secret-0123456789abcdef');
  params.set('/vinylo/play-sa', JSON.stringify({ client_email: 'sa@p.iam.gserviceaccount.com', private_key: playKey }));
  table = (await import('./stubs/dynamodb.mjs')).table;
  ({ handler } = await import('../src/index.mjs'));
});

const T0 = Date.parse('2026-11-20T03:00:00Z'); // 12:00 in Seoul
const call = (method, path, { tok, body, now = T0 } = {}) => handler({
  requestContext: { http: { method } }, rawPath: path,
  headers: tok ? { authorization: `Bearer ${tok}` } : {}, body: body ? JSON.stringify(body) : undefined,
}, {}, now).then((r) => ({ status: r.statusCode, json: r.body ? JSON.parse(r.body) : null }));

let appleSession, googleSession;

test('Apple sign-in gives a session and keeps the name sent the first time', async () => {
  let r = await call('POST', '/v1/me', { tok: apple(), body: { name: 'Kim', country: 'kr', age14Confirmed: true, termsAgreed: true } });
  assert.equal(r.status, 200);
  assert.equal(r.json.user.nickname, 'Kim');
  assert.equal(r.json.user.country, 'KR');
  assert.equal(r.json.user.age14Confirmed, true);
  assert.equal(r.json.user.termsAgreedAt, new Date(T0).toISOString());
  assert.equal(r.json.user.coinBalance, 0);
  appleSession = r.json.session.token;
  r = await call('POST', '/v1/me', { tok: apple({ email: undefined }), now: T0 + 1000 });
  assert.equal(r.json.user.userId, 'apple:a1');
  assert.equal(r.json.user.nickname, 'Kim');
  assert.equal(r.json.user.email, 'r@privaterelay.appleid.com');
  assert.equal(r.json.user.termsAgreedAt, new Date(T0).toISOString());
  assert.equal(r.json.user.lastLoginAt, new Date(T0 + 1000).toISOString());
});

test('session tokens work for later calls; sign-in itself needs Google or Apple', async () => {
  googleSession = (await call('POST', '/v1/me', { tok: google() })).json.session.token;
  assert.equal((await call('GET', '/v1/me', { tok: googleSession })).json.user.userId, 'google:g1');
  assert.equal((await call('GET', '/v1/me', { tok: googleSession.slice(0, -2) + 'xx' })).status, 401);
  assert.equal((await call('GET', '/v1/me', { tok: googleSession, now: T0 + 31 * 86400_000 })).status, 401);
  assert.equal((await call('POST', '/v1/me', { tok: googleSession })).status, 401);
  assert.equal((await call('POST', '/v1/me', { tok: apple({ aud: 'com.other' }) })).status, 401);
  assert.equal((await call('GET', '/v1/me')).status, 401);
  const r = await call('PATCH', '/v1/me', { tok: googleSession, body: { nickname: 'Gee', country: 'JP' } });
  assert.equal(r.json.user.nickname, 'Gee');
  assert.equal((await call('PATCH', '/v1/me', { tok: googleSession, body: { country: 'Japan' } })).status, 400);
});

test('songs keep metadata only; lyrics and foreign artwork are refused', async () => {
  const song = { title: 'Day Off', artist: 'Band', appleMusicId: '1440857781', artworkUrl: 'https://is1-ssl.mzstatic.com/image/a.jpg' };
  let r = await call('PUT', '/v1/songs/s-1', { tok: appleSession, body: song });
  assert.equal(r.status, 200);
  assert.equal(r.json.songId, 's-1');
  assert.equal((await call('PUT', '/v1/songs/s-2', { tok: appleSession, body: { ...song, lyrics: 'la la' } })).status, 400);
  assert.equal((await call('PUT', '/v1/songs/s-2', { tok: appleSession, body: { ...song, artworkUrl: 'https://i.pinimg.com/x.jpg' } })).status, 400);
  assert.equal((await call('PUT', '/v1/songs/bad id', { tok: appleSession, body: song })).status, 400);
  r = await call('GET', '/v1/sync', { tok: appleSession });
  assert.deepEqual(r.json.songs.map((s) => s.title), ['Day Off']);
});

test('quiz keeps the best score per level', async () => {
  await call('PUT', '/v1/quiz/s-1/2', { tok: appleSession, body: { score: 80 } });
  await call('PUT', '/v1/quiz/s-1/2', { tok: appleSession, body: { score: 60 } });
  const r = await call('PUT', '/v1/quiz/s-1/2', { tok: appleSession, body: { score: 70 } });
  assert.equal(r.json.score, 80);
  assert.equal((await call('PUT', '/v1/quiz/s-1/6', { tok: appleSession, body: { score: 70 } })).status, 400);
});

test('conquering pays a bonus coin once, even after un-conquering', async () => {
  let r = await call('PUT', '/v1/conquered/s-1', { tok: appleSession });
  assert.deepEqual([r.json.bonusCoins, r.json.coinBalance], [1, 1]);
  await call('DELETE', '/v1/conquered/s-1', { tok: appleSession });
  assert.equal((await call('GET', '/v1/sync', { tok: appleSession })).json.conquered.length, 0);
  r = await call('PUT', '/v1/conquered/s-1', { tok: appleSession });
  assert.deepEqual([r.json.bonusCoins, r.json.coinBalance], [0, 1]);
});

test('daily coin once per Seoul day; uploads spend a coin', async () => {
  assert.equal((await call('POST', '/v1/coins/daily', { tok: appleSession })).json.coinBalance, 2);
  assert.equal((await call('POST', '/v1/coins/daily', { tok: appleSession, now: T0 + 3600_000 })).status, 409);
  // 15:00 UTC is midnight in Seoul: a new day.
  assert.equal((await call('POST', '/v1/coins/daily', { tok: appleSession, now: Date.parse('2026-11-20T15:00:00Z') })).json.coinBalance, 3);
  for (let i = 0; i < 3; i++) assert.equal((await call('POST', '/v1/coins/spend', { tok: appleSession, body: { reason: 'upload', songId: 's-1' } })).status, 200);
  const r = await call('POST', '/v1/coins/spend', { tok: appleSession, body: { reason: 'upload' } });
  assert.deepEqual([r.status, r.json.coinBalance], [402, 0]);
  const ledger = (await call('GET', '/v1/coins', { tok: appleSession })).json.ledger;
  // Newest first; entries made in the same millisecond have no fixed order.
  assert.equal(ledger[0].reason, 'daily');
  assert.deepEqual(ledger.map((l) => l.reason).sort(), ['conquer', 'daily', 'daily', 'upload', 'upload', 'upload']);
  assert.equal(ledger.reduce((n, l) => n + l.change, 0), 0);
});

test('the daily coin fills the balance up to 3 and no further', async () => {
  // The balance is 0 after the test above; one Seoul day after another from 11/22.
  const day = (n) => Date.parse('2026-11-21T15:00:00Z') + n * 86_400_000;
  for (let n = 0; n < 3; n++) assert.equal((await call('POST', '/v1/coins/daily', { tok: appleSession, now: day(n) })).json.coinBalance, n + 1);
  const r = await call('POST', '/v1/coins/daily', { tok: appleSession, now: day(3) });
  assert.deepEqual([r.status, r.json.given, r.json.full, r.json.coinBalance], [409, false, true, 3]);
  // Already taken today is not "full".
  const again = await call('POST', '/v1/coins/daily', { tok: appleSession, now: day(2) + 3600_000 });
  assert.equal(again.json.full, false);
  // After spending one, the next day refills again.
  await call('POST', '/v1/coins/spend', { tok: appleSession, body: { reason: 'upload', songId: 's-1' } });
  assert.equal((await call('POST', '/v1/coins/daily', { tok: appleSession, now: day(4) })).json.coinBalance, 3);
});

test('Google Play purchases: verified, acknowledged, granted once, one account per token', async () => {
  play.set('tok-coins', { purchaseState: 0, acknowledgementState: 0, orderId: 'GPA.1', purchaseTimeMillis: `${T0}` });
  calls.length = 0;
  let r = await call('POST', '/v1/purchases', { tok: googleSession, body: { platform: 'android', productId: 'coins_10', purchaseToken: 'tok-coins' } });
  assert.deepEqual([r.status, r.json.result, r.json.coinBalance], [200, 'new', 10]);
  assert.ok(calls.some(([m, u]) => m === 'POST' && u.endsWith('/products/coins_10/tokens/tok-coins:acknowledge')));
  r = await call('POST', '/v1/purchases', { tok: googleSession, body: { platform: 'android', productId: 'coins_10', purchaseToken: 'tok-coins' } });
  assert.deepEqual([r.json.result, r.json.coinBalance], ['updated', 10]);
  r = await call('POST', '/v1/purchases', { tok: appleSession, body: { platform: 'android', productId: 'coins_10', purchaseToken: 'tok-coins' } });
  assert.equal(r.status, 409);
  assert.equal((await call('POST', '/v1/purchases', { tok: googleSession, body: { platform: 'android', productId: 'coins_10', purchaseToken: 'nope' } })).status, 400);
  assert.equal((await call('POST', '/v1/purchases', { tok: googleSession, body: { platform: 'android', productId: 'free_lunch', purchaseToken: 'x' } })).status, 400);
  play.set('tok-pending', { purchaseState: 2, acknowledgementState: 0 });
  assert.equal((await call('POST', '/v1/purchases', { tok: googleSession, body: { platform: 'android', productId: 'coins_10', purchaseToken: 'tok-pending' } })).status, 202);

  play.set('tok-sub', {
    subscriptionState: 'SUBSCRIPTION_STATE_ACTIVE', acknowledgementState: 'ACKNOWLEDGEMENT_STATE_PENDING', latestOrderId: 'GPA.2',
    lineItems: [{ productId: 'unlimited_monthly', expiryTime: '2026-12-01T03:00:00Z' }],
  });
  r = await call('POST', '/v1/purchases', { tok: googleSession, body: { platform: 'android', productId: 'unlimited_monthly', purchaseToken: 'tok-sub' } });
  assert.deepEqual([r.json.unlimitedUpload, r.json.unlimitedExpiresAt], [true, '2026-12-01T03:00:00.000Z']);
  r = await call('POST', '/v1/coins/spend', { tok: googleSession, body: { reason: 'upload' } });
  assert.deepEqual([r.json.spent, r.json.coinBalance], [0, 10]);
  // After the subscription ends, uploads cost coins again.
  r = await call('POST', '/v1/coins/spend', { tok: googleSession, body: { reason: 'upload' }, now: Date.parse('2026-12-02T00:00:00Z') });
  assert.deepEqual([r.json.spent, r.json.coinBalance], [1, 9]);
  const purchases = (await call('GET', '/v1/sync', { tok: googleSession })).json.purchases;
  assert.equal(purchases.length, 2);
  assert.ok(purchases.every((p) => !('purchaseToken' in p)));
});

test('AI translation reports keep song, line number and engine, never lyric text', async () => {
  const report = { reason: 'offensive', title: 'Day Off', artist: 'Band', lineIndex: 4, engine: 'gemini', model: 'gemini-2.5-flash', promptVersion: 'p3', targetLanguage: 'ko', comment: '너무 셉니다' };
  assert.equal((await call('POST', '/v1/reports', { tok: appleSession, body: report })).status, 200);
  assert.equal((await call('POST', '/v1/reports', { tok: appleSession, body: { ...report, original: 'lyric line' } })).status, 400);
  assert.equal((await call('POST', '/v1/reports', { tok: appleSession, body: { ...report, reason: 'meh' } })).status, 400);
  const stored = [...table.values()].filter((i) => i.pk.S === 'reports');
  assert.equal(stored.length, 1);
  assert.equal(stored[0].reason.S, 'offensive');
});

test('deleting an account removes every item, its reports and purchase tokens; Apple tokens are revoked', async () => {
  calls.length = 0;
  let r = await call('DELETE', '/v1/me', { tok: appleSession, body: { authorizationCode: 'code1' } });
  assert.equal(r.status, 200);
  assert.equal(r.json.appleTokensRevoked, true);
  assert.deepEqual(calls.map(([, u]) => u), ['https://appleid.apple.com/auth/token', 'https://appleid.apple.com/auth/revoke']);
  assert.equal([...table.values()].filter((i) => i.pk.S === 'apple:a1' || i.pk.S === 'reports').length, 0);
  assert.equal((await call('GET', '/v1/me', { tok: appleSession })).status, 404);

  r = await call('DELETE', '/v1/me', { tok: googleSession });
  assert.equal(r.json.appleTokensRevoked, false);
  assert.equal(table.size, 0);
});

test('health and unknown paths', async () => {
  assert.equal((await call('GET', '/health')).status, 200);
  assert.equal((await call('GET', '/nope')).status, 404);
  assert.equal((await call('GET', '/v1/nope', { tok: googleSession })).status, 404);
});
