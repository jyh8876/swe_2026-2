// Pure logic for the Vinylo account server: Apple Music developer tokens, Google and Apple ID
// token checks, and Sign in with Apple token revocation. No AWS calls here, so it can be tested locally with `node --test`.
import { createPrivateKey, createPublicKey, sign, verify } from 'node:crypto';

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
