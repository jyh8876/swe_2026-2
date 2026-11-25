// Vinylo server: AWS Lambda behind a Function URL (payload format 2.0). What it keeps follows the
// privacy policy draft (Notion 11/19): users, song metadata, quiz scores, conquered songs, coins,
// purchases and entitlements. Lyrics, translations, quiz questions, API keys and card details
// never reach it. The routes are listed in README.md.
//
// Auth: "Authorization: Bearer <token>". POST /v1/me takes a Google ID token or an Apple identity
// token and returns a Vinylo session token (30 days); every other /v1 call takes either.
// Only the AWS SDK built into the Lambda Node.js runtime is used, so the zip is just this folder.
import { SSMClient, GetParameterCommand } from '@aws-sdk/client-ssm';
import {
  appleClientSecret, appleMusicToken, AuthError, checkId, COIN, coinDay, DAILY_COIN_CAP, googleServiceAssertion, InputError,
  isSessionToken, JwksCache, productStatus, profileInput, quizInput, reportInput, revokeAppleTokens, sessionToken,
  songInput, subscriptionStatus, TokenCache, tokenHash, tokenProvider, unlimitedActive, verifyIdToken, verifySession,
} from './core.mjs';
import * as db from './store.mjs';

const env = process.env;
const ssm = new SSMClient({});
const list = (v) => `${v ?? ''}`.split(',').map((s) => s.trim()).filter(Boolean);

const secrets = new Map();
async function secret(name) {
  if (!secrets.has(name)) {
    const out = await ssm.send(new GetParameterCommand({ Name: name, WithDecryption: true }));
    secrets.set(name, out.Parameter?.Value);
  }
  return secrets.get(name);
}

// ── Apple Music ──
let tokens = null;
async function musicTokens() {
  if (tokens) return tokens;
  const p8 = await secret(env.MUSICKIT_P8_PARAM);
  tokens = new TokenCache((now) => appleMusicToken({ p8, teamId: env.TEAM_ID, keyId: env.MUSICKIT_KEY_ID, now }));
  return tokens;
}

// ── Sign-in ──
async function fetchKeys(url) {
  const r = await fetch(url);
  if (!r.ok) throw new Error(`keys ${url}: HTTP ${r.status}`);
  const maxAge = /max-age=(\d+)/.exec(r.headers.get('cache-control') ?? '')?.[1];
  return { keys: await r.json(), maxAgeSeconds: maxAge ? Number(maxAge) : 3600 };
}
const providers = {
  google: { audiences: list(env.GOOGLE_CLIENT_IDS), jwks: new JwksCache(() => fetchKeys('https://www.googleapis.com/oauth2/v3/certs')) },
  // Native iOS sign-in: the token's audience is the app's bundle ID.
  apple: { audiences: list(env.APPLE_CLIENT_IDS), jwks: new JwksCache(() => fetchKeys('https://appleid.apple.com/auth/keys')) },
};

class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

/** The caller: {userId, provider, profile?}. [idTokenOnly] refuses session tokens (sign-in). */
async function caller(headers, { idTokenOnly = false, now = Date.now() } = {}) {
  const m = /^Bearer\s+(.+)$/i.exec(headers?.authorization ?? '');
  if (!m) throw new HttpError(401, 'missing token');
  const token = m[1];
  if (isSessionToken(token)) {
    if (idTokenOnly) throw new HttpError(401, 'sign in with Google or Apple');
    const userId = verifySession(token, { secret: await secret(env.SESSION_SECRET_PARAM), now });
    return { userId, provider: userId.split(':')[0] };
  }
  const provider = tokenProvider(token);
  const p = providers[provider];
  if (!p) throw new HttpError(401, 'unknown issuer');
  if (p.audiences.length === 0) throw new HttpError(503, `${provider} sign-in is not configured`);
  const profile = verifyIdToken(token, { provider, jwks: await p.jwks.get(), audiences: p.audiences });
  return { userId: `${provider}:${profile.sub}`, provider, profile };
}

/** Revokes Apple tokens when a Sign in with Apple key is configured; false when it is not. */
async function revokeApple(code, clientId) {
  if (!code || !env.SIWA_KEY_ID || !env.SIWA_P8_PARAM) return false;
  const clientSecret = appleClientSecret({ p8: await secret(env.SIWA_P8_PARAM), teamId: env.TEAM_ID, keyId: env.SIWA_KEY_ID, clientId });
  await revokeAppleTokens({
    code, clientId, clientSecret,
    post: async (url, form) => {
      const r = await fetch(url, { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams(form) });
      return { status: r.status, json: await r.json().catch(() => ({})) };
    },
  });
  return true;
}

// ── Google Play purchases ──
let playToken = null;
async function playAccessToken(now) {
  if (playToken && playToken.until > now) return playToken.token;
  const sa = JSON.parse(await secret(env.PLAY_SA_PARAM));
  const r = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: googleServiceAssertion({ clientEmail: sa.client_email, privateKey: sa.private_key, now }),
    }),
  });
  if (!r.ok) throw new Error(`Play auth: HTTP ${r.status}`);
  const j = await r.json();
  playToken = { token: j.access_token, until: now + ((j.expires_in ?? 3600) - 300) * 1000 };
  return playToken.token;
}

/** What a product gives: {coins} for a coin pack, {unlimited, subscription} for unlimited uploads. */
function productGrant(productId) {
  const coins = Object.fromEntries(list(env.COIN_PRODUCTS).map((p) => p.split(':')).map(([id, n]) => [id, Number(n)]));
  if (coins[productId] > 0) return { coins: coins[productId] };
  if (list(env.UNLIMITED_PRODUCTS).includes(productId)) return { unlimited: true, subscription: false };
  if (list(env.UNLIMITED_SUBSCRIPTIONS).includes(productId)) return { unlimited: true, subscription: true };
  return null;
}

/** Asks Google Play about a purchase and acknowledges it, so Play does not refund it after 3 days. */
async function verifyPlayPurchase(productId, purchaseToken, grant, now) {
  const api = `https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${env.PLAY_PACKAGE}/purchases`;
  const auth = { authorization: `Bearer ${await playAccessToken(now)}` };
  const t = encodeURIComponent(purchaseToken);
  const url = grant.subscription ? `${api}/subscriptionsv2/tokens/${t}` : `${api}/products/${encodeURIComponent(productId)}/tokens/${t}`;
  const r = await fetch(url, { headers: auth });
  if (r.status === 400 || r.status === 404 || r.status === 410) throw new HttpError(400, 'purchase not found');
  if (!r.ok) throw new Error(`Play verify: HTTP ${r.status}`);
  const p = await r.json();
  const { status, expiresAt } = grant.subscription ? subscriptionStatus(p) : { status: productStatus(p), expiresAt: null };
  if (grant.subscription && !(p.lineItems ?? []).some((l) => l.productId === productId)) throw new HttpError(400, 'product does not match');
  const acked = grant.subscription ? p.acknowledgementState === 'ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED' : p.acknowledgementState === 1;
  if (status === 'purchased' && !acked) {
    const ack = grant.subscription ? `${api}/subscriptions/${encodeURIComponent(productId)}/tokens/${t}:acknowledge` : `${url}:acknowledge`;
    const a = await fetch(ack, { method: 'POST', headers: { ...auth, 'content-type': 'application/json' }, body: '{}' });
    if (!a.ok) throw new Error(`Play acknowledge: HTTP ${a.status}`);
  }
  return {
    status, expiresAt,
    orderId: p.orderId ?? p.latestOrderId ?? null,
    purchasedAt: p.purchaseTimeMillis ? new Date(Number(p.purchaseTimeMillis)).toISOString() : (p.startTime ?? null),
    acknowledged: status === 'purchased',
  };
}

// ── HTTP ──
function reply(status, body, headers = {}) {
  return {
    statusCode: status,
    headers: { 'content-type': 'application/json', 'cache-control': 'no-store', ...headers },
    body: body == null ? '' : JSON.stringify(body),
  };
}

function jsonBody(event) {
  if (!event.body) return {};
  let j;
  try {
    const text = event.isBase64Encoded ? Buffer.from(event.body, 'base64').toString() : event.body;
    if (text.length > 8000) throw new HttpError(413, 'body too large');
    j = JSON.parse(text);
  } catch (e) {
    if (e instanceof HttpError) throw e;
    throw new HttpError(400, 'body must be JSON');
  }
  if (!j || typeof j !== 'object' || Array.isArray(j)) throw new HttpError(400, 'body must be a JSON object');
  return j;
}

/** The user's profile as the app sees it (no internal keys). */
function publicProfile(p, now) {
  if (!p) return null;
  const { pk, sk, lastRefillDay, ...rest } = p;
  return { ...rest, unlimitedUpload: unlimitedActive(p, now) };
}
const strip = ({ pk, sk, ...rest }) => rest;

async function signIn(event, now) {
  const who = await caller(event.headers, { idTokenOnly: true, now });
  const body = jsonBody(event);
  const fields = profileInput(body);
  const p = who.profile;
  // Apple never puts the name in the token; the app sends it once, on the first sign-in.
  const nickname = fields.nickname ?? p.name ?? (typeof body.name === 'string' ? body.name.trim().slice(0, 40) || null : null);
  const profile = await db.upsertProfile(who.userId, {
    userId: who.userId,
    provider: who.provider,
    providerSub: p.sub,
    email: p.email,
    nickname,
    country: fields.country,
    age14Confirmed: fields.age14Confirmed,
    termsAgreedAt: fields.termsAgreed ? new Date(now).toISOString() : null,
  }, now);
  const session = sessionToken({ secret: await secret(env.SESSION_SECRET_PARAM), userId: who.userId, now });
  return reply(200, { user: publicProfile(profile, now), session });
}

async function route(event, now) {
  const method = event.requestContext?.http?.method ?? 'GET';
  const path = (event.rawPath ?? '/').replace(/\/+$/, '') || '/';
  const m = (re) => re.exec(path);

  if (path === '/health' && method === 'GET') return reply(200, { ok: true });
  if (path === '/apple-music/token' && method === 'GET') {
    const { token, expiresAt } = (await musicTokens()).get();
    return reply(200, { token, expiresAt });
  }
  if (!path.startsWith('/v1/')) return reply(404, { error: 'not found' });

  if (path === '/v1/me' && method === 'POST') return signIn(event, now);

  const who = await caller(event.headers, { now });
  const uid = who.userId;
  const needProfile = async () => {
    const p = await db.getProfile(uid);
    if (!p) throw new HttpError(404, 'not registered');
    return p;
  };

  if (path === '/v1/me') {
    if (method === 'GET') return reply(200, { user: publicProfile(await needProfile(), now) });
    if (method === 'PATCH') {
      const f = profileInput(jsonBody(event));
      const { termsAgreed, ...rest } = f;
      if (termsAgreed) rest.termsAgreedAt = new Date(now).toISOString();
      try {
        return reply(200, { user: publicProfile(await db.updateProfile(uid, rest), now) });
      } catch (e) {
        if (e instanceof db.ConditionFailed) throw new HttpError(404, 'not registered');
        throw e;
      }
    }
    if (method === 'DELETE') {
      const body = jsonBody(event);
      let revoked = false;
      // The bundle ID the token was issued to is the client ID for Apple's endpoints.
      if (who.provider === 'apple') revoked = await revokeApple(body.authorizationCode, list(env.APPLE_CLIENT_IDS)[0]);
      const removed = await db.deleteUser(uid);
      return reply(200, { deleted: true, items: removed, appleTokensRevoked: revoked });
    }
    return reply(405, { error: 'method not allowed' });
  }

  if (path === '/v1/sync' && method === 'GET') {
    const items = await db.allItems(uid);
    const pick = (prefix) => items.filter((i) => i.sk.startsWith(prefix)).map(strip);
    const profile = items.find((i) => i.sk === 'profile');
    if (!profile) throw new HttpError(404, 'not registered');
    return reply(200, {
      user: publicProfile(profile, now),
      songs: pick('song#'),
      quiz: pick('quiz#'),
      conquered: pick('conq#').filter((c) => c.conqueredAt),
      purchases: pick('purchase#').map(({ purchaseToken, tokenHash: _, ...p }) => p),
    });
  }

  let r;
  if ((r = m(/^\/v1\/songs\/([^/]+)$/))) {
    const songId = checkId(r[1], 'songId');
    if (method === 'PUT') return reply(200, strip(await db.putSong(uid, songId, songInput(jsonBody(event)), now)));
    if (method === 'DELETE') {
      await db.deleteSong(uid, songId);
      return reply(200, { deleted: true });
    }
    return reply(405, { error: 'method not allowed' });
  }

  if ((r = m(/^\/v1\/quiz\/([^/]+)\/([^/]+)$/)) && method === 'PUT') {
    const songId = checkId(r[1], 'songId');
    return reply(200, strip(await db.putQuiz(uid, songId, quizInput(r[2], jsonBody(event)), now)));
  }

  if ((r = m(/^\/v1\/conquered\/([^/]+)$/))) {
    const songId = checkId(r[1], 'songId');
    await needProfile();
    if (method === 'PUT') {
      const at = jsonBody(event).conqueredAt;
      const when = at && !Number.isNaN(new Date(at).getTime()) ? new Date(at).toISOString() : new Date(now).toISOString();
      const { bonus } = await db.conquer(uid, songId, COIN.conquer, when, now);
      return reply(200, { songId, conqueredAt: when, bonusCoins: bonus, coinBalance: (await db.getProfile(uid)).coinBalance });
    }
    if (method === 'DELETE') {
      await db.unconquer(uid, songId);
      return reply(200, { songId, conqueredAt: null });
    }
    return reply(405, { error: 'method not allowed' });
  }

  if (path === '/v1/coins' && method === 'GET') {
    const p = await needProfile();
    const ledger = (await db.allItems(uid, 'coin#')).map(strip).reverse().slice(0, 50);
    return reply(200, { coinBalance: p.coinBalance ?? 0, lastRefillAt: p.lastRefillAt ?? null, unlimitedUpload: unlimitedActive(p, now), ledger });
  }
  if (path === '/v1/coins/daily' && method === 'POST') {
    await needProfile();
    const day = coinDay(now, Number(env.COIN_DAY_OFFSET_MINUTES ?? 540));
    const given = await db.claimDaily(uid, COIN.daily, day, now, DAILY_COIN_CAP);
    const p = await db.getProfile(uid);
    // full: not given because the balance is already at the cap (not because today's coin was taken).
    const full = !given && p.lastRefillDay !== day && (p.coinBalance ?? 0) >= DAILY_COIN_CAP;
    return reply(given ? 200 : 409, { given, full, coinBalance: p.coinBalance, lastRefillAt: p.lastRefillAt ?? null });
  }
  if (path === '/v1/coins/spend' && method === 'POST') {
    const body = jsonBody(event);
    if (body.reason !== 'upload') throw new InputError('reason must be upload');
    const songId = body.songId == null ? null : checkId(body.songId, 'songId');
    const p = await needProfile();
    if (unlimitedActive(p, now)) return reply(200, { spent: 0, coinBalance: p.coinBalance, unlimitedUpload: true });
    const ok = await db.spendCoins(uid, COIN.upload, 'upload', songId, now);
    const after = await db.getProfile(uid);
    return reply(ok ? 200 : 402, { spent: ok ? -COIN.upload : 0, coinBalance: after.coinBalance, unlimitedUpload: false });
  }

  if (path === '/v1/purchases' && method === 'POST') {
    const body = jsonBody(event);
    if (body.platform !== 'android') throw new HttpError(501, 'only Google Play purchases are checked so far');
    if (!env.PLAY_SA_PARAM || !env.PLAY_PACKAGE) throw new HttpError(503, 'purchases are not configured');
    const productId = typeof body.productId === 'string' ? body.productId : '';
    const purchaseToken = typeof body.purchaseToken === 'string' ? body.purchaseToken : '';
    if (!productId || !purchaseToken || purchaseToken.length > 1000) throw new InputError('productId and purchaseToken are required');
    const grant = productGrant(productId);
    if (!grant) throw new InputError('unknown product');
    await needProfile();
    const v = await verifyPlayPurchase(productId, purchaseToken, grant, now);
    // Pending (e.g. cash payment) is not recorded; the app sends it again once it completes.
    if (v.status !== 'purchased') return reply(202, { status: v.status });
    const hash = tokenHash(purchaseToken);
    const result = await db.recordPurchase(uid, {
      tokenHash: hash, purchaseToken, productId, orderId: v.orderId, platform: 'android', status: v.status,
      purchasedAt: v.purchasedAt, acknowledged: v.acknowledged,
    }, { coins: grant.coins, unlimited: grant.unlimited, unlimitedExpiresAt: v.expiresAt }, now);
    if (result === 'taken') throw new HttpError(409, 'purchase belongs to another account');
    const p = await db.getProfile(uid);
    return reply(200, { status: v.status, result, coinBalance: p.coinBalance, unlimitedUpload: unlimitedActive(p, now), unlimitedExpiresAt: p.unlimitedExpiresAt ?? null });
  }

  if (path === '/v1/reports' && method === 'POST') {
    await needProfile();
    const id = await db.putReport(uid, reportInput(jsonBody(event)), now);
    return reply(200, { reported: true, id });
  }

  return reply(404, { error: 'not found' });
}

export async function handler(event, _context, now = Date.now()) {
  try {
    return await route(event, now);
  } catch (e) {
    if (e instanceof HttpError) return reply(e.status, { error: e.message });
    if (e instanceof AuthError) return reply(401, { error: e.message });
    if (e instanceof InputError) return reply(400, { error: e.message });
    // Details go to CloudWatch only (never tokens or keys).
    console.error(event.rawPath, event.requestContext?.http?.method, e?.name, e?.message);
    return reply(500, { error: 'server error' });
  }
}
