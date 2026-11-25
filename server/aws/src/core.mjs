// Pure logic for the Vinylo server: Apple Music developer tokens, Google and Apple ID token checks,
// Sign in with Apple token revocation, sessions, input checks, coin rules and Play purchases. No AWS calls here, so it can be tested locally with `node --test`.
import { createHash, createHmac, createPrivateKey, createPublicKey, sign, timingSafeEqual, verify } from 'node:crypto';

const b64url = (buf) => Buffer.from(buf).toString('base64url');
const json64 = (obj) => b64url(JSON.stringify(obj));

// ─────────────────────────── Apple Music developer token ───────────────────────────

/** Apple allows at most 6 months (15777000 s). Tokens are re-issued before they expire. */
export const MAX_TOKEN_SECONDS = 15777000;

/**
 * ES256 JWT for MusicKit: header {alg, kid}, payload {iss: Team ID, iat, exp}.
 * [p8] is the PEM text of the MusicKit private key.
 */
export function appleMusicToken({ p8, teamId, keyId, now = Date.now(), ttlSeconds = 30 * 24 * 3600 }) {
  if (!p8 || !teamId || !keyId) throw new Error('MusicKit key, Team ID and Key ID are required');
  const iat = Math.floor(now / 1000);
  const exp = iat + Math.min(ttlSeconds, MAX_TOKEN_SECONDS);
  const input = `${json64({ alg: 'ES256', kid: keyId })}.${json64({ iss: teamId, iat, exp })}`;
  // JWT wants the raw r||s signature, not DER.
  const sig = sign('sha256', Buffer.from(input), { key: createPrivateKey(p8), dsaEncoding: 'ieee-p1363' });
  return { token: `${input}.${b64url(sig)}`, expiresAt: exp };
}

/** Keeps one token per warm Lambda and replaces it when less than [refreshSeconds] is left. */
export class TokenCache {
  constructor(make, refreshSeconds = 7 * 24 * 3600) {
    this.make = make;
    this.refreshSeconds = refreshSeconds;
    this.current = null;
  }

  get(now = Date.now()) {
    const c = this.current;
    if (!c || c.expiresAt - now / 1000 < this.refreshSeconds) this.current = this.make(now);
    return this.current;
  }
}

// ─────────────────────────── ID tokens (Google, Apple) ───────────────────────────

const ISSUERS = {
  google: new Set(['accounts.google.com', 'https://accounts.google.com']),
  apple: new Set(['https://appleid.apple.com']),
};

export class AuthError extends Error {}

function decodeJwt(token) {
  const parts = `${token ?? ''}`.split('.');
  if (parts.length !== 3) throw new AuthError('malformed token');
  try {
    return { parts, header: JSON.parse(Buffer.from(parts[0], 'base64url')), payload: JSON.parse(Buffer.from(parts[1], 'base64url')) };
  } catch {
    throw new AuthError('malformed token');
  }
}

/** Which provider issued [token], from its (still unverified) issuer; null if neither. */
export function tokenProvider(token) {
  const { payload } = decodeJwt(token);
  for (const [provider, issuers] of Object.entries(ISSUERS)) if (issuers.has(payload.iss)) return provider;
  return null;
}

/**
 * Checks an RS256 ID token from [provider] ('google' or 'apple') against the provider's public
 * keys [jwks] ({keys: [...]}) and the app's client IDs [audiences] (Google OAuth client IDs, or
 * the iOS bundle ID for Apple). Returns the profile the server keeps.
 */
export function verifyIdToken(idToken, { provider, jwks, audiences, now = Date.now() }) {
  const { parts, header, payload } = decodeJwt(idToken);
  if (header.alg !== 'RS256') throw new AuthError('unexpected algorithm');
  const jwk = (jwks?.keys ?? []).find((k) => k.kid === header.kid);
  if (!jwk) throw new AuthError('unknown key');
  const ok = verify('sha256', Buffer.from(`${parts[0]}.${parts[1]}`), createPublicKey({ key: jwk, format: 'jwk' }),
    Buffer.from(parts[2], 'base64url'));
  if (!ok) throw new AuthError('bad signature');
  if (!ISSUERS[provider]?.has(payload.iss)) throw new AuthError('wrong issuer');
  if (!audiences.includes(payload.aud)) throw new AuthError('wrong audience');
  const t = now / 1000;
  // A minute of leeway for clock drift.
  if (typeof payload.exp !== 'number' || payload.exp < t - 60) throw new AuthError('expired');
  if (typeof payload.iat === 'number' && payload.iat > t + 60) throw new AuthError('issued in the future');
  if (!payload.sub) throw new AuthError('no subject');
  return {
    provider,
    sub: `${payload.sub}`,
    email: payload.email ? `${payload.email}` : null,
    emailVerified: payload.email_verified === true || payload.email_verified === 'true',
    // Apple never puts the name in the token; the app sends it once, on the first sign-in.
    name: payload.name ? `${payload.name}`.slice(0, 200) : null,
  };
}

/** Kept for callers of the Google-only check. */
export const verifyGoogleIdToken = (idToken, opts) => verifyIdToken(idToken, { ...opts, provider: 'google' });

// ─────────────────────────── Sign in with Apple: token revocation ───────────────────────────

/**
 * Client secret for Apple's token endpoints: ES256 JWT {iss: Team ID, aud: appleid.apple.com,
 * sub: client ID (bundle ID)} signed with a Sign in with Apple key ([p8], [keyId]).
 */
export function appleClientSecret({ p8, teamId, keyId, clientId, now = Date.now(), ttlSeconds = 300 }) {
  const iat = Math.floor(now / 1000);
  const input = `${json64({ alg: 'ES256', kid: keyId })}.${json64({ iss: teamId, iat, exp: iat + ttlSeconds, aud: 'https://appleid.apple.com', sub: clientId })}`;
  const sig = sign('sha256', Buffer.from(input), { key: createPrivateKey(p8), dsaEncoding: 'ieee-p1363' });
  return `${input}.${b64url(sig)}`;
}

/**
 * Revokes a user's Apple tokens on account deletion (App Store guideline 5.1.1(v)): the app's
 * one-time [code] is exchanged for a refresh token, which is then revoked. [post] is
 * (url, form) => Promise<{status, json}>.
 */
export async function revokeAppleTokens({ code, clientId, clientSecret, post }) {
  const t = await post('https://appleid.apple.com/auth/token',
    { client_id: clientId, client_secret: clientSecret, code, grant_type: 'authorization_code' });
  if (t.status !== 200) throw new Error(`Apple token exchange: HTTP ${t.status} ${t.json?.error ?? ''}`.trim());
  const token = t.json.refresh_token ?? t.json.access_token;
  const hint = t.json.refresh_token ? 'refresh_token' : 'access_token';
  const r = await post('https://appleid.apple.com/auth/revoke',
    { client_id: clientId, client_secret: clientSecret, token, token_type_hint: hint });
  if (r.status !== 200) throw new Error(`Apple revoke: HTTP ${r.status}`);
}

/** A provider's public keys, cached for as long as its Cache-Control says (default one hour). */
export class JwksCache {
  constructor(fetchKeys) {
    this.fetchKeys = fetchKeys;
    this.keys = null;
    this.until = 0;
  }

  async get(now = Date.now()) {
    if (!this.keys || now >= this.until) {
      const { keys, maxAgeSeconds } = await this.fetchKeys();
      this.keys = keys;
      this.until = now + (maxAgeSeconds ?? 3600) * 1000;
    }
    return this.keys;
  }
}

// ─────────────────────────── User record ───────────────────────────

/**
 * The only data kept per user: account id, email, name and two timestamps. No lyrics,
 * songs, translations or listening history.
 */
export function userRecord(profile, now = new Date()) {
  const provider = profile.provider ?? 'google';
  return {
    userId: `${provider}:${profile.sub}`,
    provider,
    email: profile.email,
    name: profile.name,
    lastSeenAt: now.toISOString(),
  };
}

// ─────────────────────────── Sessions ───────────────────────────
// Signing in with Google or Apple gives the app a Vinylo session token (HS256 JWT, 30 days), so
// later calls do not need a fresh Google or Apple token (Apple's lasts only 10 minutes).

export const SESSION_ISSUER = 'vinylo';
export const SESSION_SECONDS = 30 * 24 * 3600;

export function sessionToken({ secret, userId, now = Date.now(), ttlSeconds = SESSION_SECONDS }) {
  if (!secret || !userId) throw new Error('session secret and user id are required');
  const iat = Math.floor(now / 1000);
  const exp = iat + ttlSeconds;
  const input = `${json64({ alg: 'HS256', typ: 'JWT' })}.${json64({ iss: SESSION_ISSUER, sub: userId, iat, exp })}`;
  return { token: `${input}.${b64url(createHmac('sha256', secret).update(input).digest())}`, expiresAt: exp };
}

/** True when [token] claims to be a Vinylo session (not yet verified). */
export function isSessionToken(token) {
  try {
    return decodeJwt(token).payload.iss === SESSION_ISSUER;
  } catch {
    return false;
  }
}

/** Returns the user id of a valid session token. */
export function verifySession(token, { secret, now = Date.now() }) {
  const { parts, header, payload } = decodeJwt(token);
  if (header.alg !== 'HS256' || payload.iss !== SESSION_ISSUER) throw new AuthError('not a session');
  const want = createHmac('sha256', secret).update(`${parts[0]}.${parts[1]}`).digest();
  const got = Buffer.from(parts[2], 'base64url');
  if (got.length !== want.length || !timingSafeEqual(got, want)) throw new AuthError('bad signature');
  if (typeof payload.exp !== 'number' || payload.exp < now / 1000) throw new AuthError('expired');
  if (typeof payload.sub !== 'string' || !payload.sub) throw new AuthError('no subject');
  return payload.sub;
}

// ─────────────────────────── Input checks ───────────────────────────

export class InputError extends Error {}

const str = (v, max, field, { required = false } = {}) => {
  if (v == null || v === '') {
    if (required) throw new InputError(`${field} is required`);
    return null;
  }
  if (typeof v !== 'string') throw new InputError(`${field} must be a string`);
  const t = v.trim();
  if (t.length > max) throw new InputError(`${field} is too long`);
  if (!t && required) throw new InputError(`${field} is required`);
  return t || null;
};
const iso = (v, field) => {
  if (v == null) return null;
  const d = new Date(v);
  if (typeof v !== 'string' || Number.isNaN(d.getTime())) throw new InputError(`${field} must be an ISO date`);
  return d.toISOString();
};

/** Ids the app makes (UUIDs) or store ids: letters, digits, - and _ only. */
export function checkId(v, field = 'id') {
  if (typeof v !== 'string' || !/^[A-Za-z0-9_-]{1,64}$/.test(v)) throw new InputError(`bad ${field}`);
  return v;
}

/** Artwork only from the official catalog image hosts; covers the user picked never leave the phone. */
const ARTWORK_HOSTS = [/\.mzstatic\.com$/, /^i\.scdn\.co$/, /\.spotifycdn\.com$/];
export function checkArtworkUrl(v) {
  if (v == null || v === '') return null;
  let u;
  try {
    u = new URL(v);
  } catch {
    throw new InputError('artworkUrl must be a URL');
  }
  if (u.protocol !== 'https:' || !ARTWORK_HOSTS.some((h) => h.test(u.hostname)) || v.length > 500) {
    throw new InputError('artworkUrl must be an Apple Music or Spotify image URL');
  }
  return v;
}

/** Song metadata only (Notion 11/19: no lyrics, no translations, no quiz text). */
export function songInput(body) {
  const isrc = str(body.isrc, 12, 'isrc');
  if (isrc && !/^[A-Z]{2}[A-Z0-9]{3}\d{7}$/i.test(isrc)) throw new InputError('bad isrc');
  const appleMusicId = str(body.appleMusicId, 32, 'appleMusicId');
  if (appleMusicId && !/^\d+$/.test(appleMusicId)) throw new InputError('bad appleMusicId');
  for (const k of ['lyrics', 'lines', 'translations', 'text']) {
    if (k in body) throw new InputError(`${k} is not stored on the server`);
  }
  return {
    title: str(body.title, 300, 'title', { required: true }),
    artist: str(body.artist, 300, 'artist', { required: true }),
    appleMusicId,
    isrc: isrc?.toUpperCase() ?? null,
    artworkUrl: checkArtworkUrl(body.artworkUrl),
    addedAt: iso(body.addedAt, 'addedAt'),
  };
}

export const QUIZ_LEVELS = 5;
export function quizInput(level, body) {
  const l = Number(level);
  if (!Number.isInteger(l) || l < 1 || l > QUIZ_LEVELS) throw new InputError('level must be 1 to 5');
  const score = Number(body.score);
  if (!Number.isFinite(score) || score < 0 || score > 100) throw new InputError('score must be 0 to 100');
  return { level: l, score: Math.round(score), completedAt: iso(body.completedAt, 'completedAt') };
}

export function profileInput(body) {
  const out = {};
  if ('nickname' in body) out.nickname = str(body.nickname, 40, 'nickname');
  if ('country' in body) {
    const c = str(body.country, 2, 'country');
    if (c && !/^[A-Za-z]{2}$/.test(c)) throw new InputError('country must be a 2-letter code');
    out.country = c?.toUpperCase() ?? null;
  }
  if ('age14Confirmed' in body) {
    if (typeof body.age14Confirmed !== 'boolean') throw new InputError('age14Confirmed must be true or false');
    out.age14Confirmed = body.age14Confirmed;
  }
  if (body.termsAgreed === true) out.termsAgreed = true;
  return out;
}

export const REPORT_REASONS = ['wrong', 'awkward', 'offensive', 'reading', 'other'];
/** AI translation report: which song and line, what is wrong, which engine. No lyric text. */
export function reportInput(body) {
  const reason = body.reason;
  if (!REPORT_REASONS.includes(reason)) throw new InputError(`reason must be one of ${REPORT_REASONS.join(', ')}`);
  let lineIndex = null;
  if (body.lineIndex != null) {
    lineIndex = Number(body.lineIndex);
    if (!Number.isInteger(lineIndex) || lineIndex < 0 || lineIndex > 5000) throw new InputError('bad lineIndex');
  }
  for (const k of ['lyrics', 'line', 'original', 'text']) {
    if (k in body) throw new InputError(`${k} is not stored on the server`);
  }
  return {
    reason,
    lineIndex,
    title: str(body.title, 300, 'title', { required: true }),
    artist: str(body.artist, 300, 'artist', { required: true }),
    comment: str(body.comment, 500, 'comment'),
    engine: str(body.engine, 40, 'engine', { required: true }),
    model: str(body.model, 120, 'model'),
    promptVersion: str(body.promptVersion, 10, 'promptVersion'),
    targetLanguage: str(body.targetLanguage, 10, 'targetLanguage'),
    appVersion: str(body.appVersion, 30, 'appVersion'),
  };
}

// ─────────────────────────── Coins ───────────────────────────

/** Coin changes per reason (Notion 11/19). 'ad' needs ad-network verification before it is used. */
export const COIN = { daily: 1, conquer: 1, upload: -1 };

/**
 * The daily coin only tops the balance up to this many (milestone: up to 3 coins are kept).
 * Coins from conquering or purchases are not capped.
 */
export const DAILY_COIN_CAP = 3;

/**
 * The day a daily coin belongs to, as YYYY-MM-DD in the given time zone offset (default UTC+9),
 * so the daily coin refills at midnight Korean time.
 */
export function coinDay(now = Date.now(), offsetMinutes = 540) {
  return new Date(now + offsetMinutes * 60_000).toISOString().slice(0, 10);
}

/** True while an unlimited-upload entitlement is active (null expiry = permanent). */
export function unlimitedActive(profile, now = Date.now()) {
  if (!profile?.unlimitedUpload) return false;
  return !profile.unlimitedExpiresAt || new Date(profile.unlimitedExpiresAt).getTime() > now;
}

// ─────────────────────────── Google Play purchases ───────────────────────────

/** OAuth assertion for a Google service account (RS256), for the Play Developer API. */
export function googleServiceAssertion({ clientEmail, privateKey, now = Date.now(), scope = 'https://www.googleapis.com/auth/androidpublisher' }) {
  const iat = Math.floor(now / 1000);
  const input = `${json64({ alg: 'RS256', typ: 'JWT' })}.${json64({ iss: clientEmail, scope, aud: 'https://oauth2.googleapis.com/token', iat, exp: iat + 3600 })}`;
  return `${input}.${b64url(sign('sha256', Buffer.from(input), createPrivateKey(privateKey)))}`;
}

/** One-time product: Play's purchaseState 0 purchased, 1 canceled, 2 pending. */
export function productStatus(p) {
  return ({ 0: 'purchased', 1: 'canceled', 2: 'pending' })[p?.purchaseState] ?? 'unknown';
}

/** Subscription (subscriptionsv2): active while paid up, with its latest expiry. */
export function subscriptionStatus(s) {
  const active = ['SUBSCRIPTION_STATE_ACTIVE', 'SUBSCRIPTION_STATE_IN_GRACE_PERIOD'].includes(s?.subscriptionState);
  const expiries = (s?.lineItems ?? []).map((l) => l.expiryTime).filter(Boolean).sort();
  return {
    status: active ? 'purchased' : s?.subscriptionState === 'SUBSCRIPTION_STATE_PENDING' ? 'pending' : 'expired',
    expiresAt: expiries.length ? new Date(expiries[expiries.length - 1]).toISOString() : null,
  };
}

/** Purchase tokens are stored hashed in the global "token already used" marker. */
export const tokenHash = (t) => createHash('sha256').update(`${t}`).digest('base64url');
