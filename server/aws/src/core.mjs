// Pure logic for the Vinylo account server: Apple Music developer tokens and Google ID token
// checks. No AWS calls here, so it can be tested locally with `node --test`.
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

// ─────────────────────────── Google ID token ───────────────────────────

const GOOGLE_ISSUERS = new Set(['accounts.google.com', 'https://accounts.google.com']);

export class AuthError extends Error {}

/**
 * Checks a Google ID token (RS256) against Google's public keys [jwks] ({keys: [...]}) and the
 * app's OAuth client IDs [audiences]. Returns the profile the server keeps.
 */
export function verifyGoogleIdToken(idToken, { jwks, audiences, now = Date.now() }) {
  const parts = `${idToken ?? ''}`.split('.');
  if (parts.length !== 3) throw new AuthError('malformed token');
  let header, payload;
  try {
    header = JSON.parse(Buffer.from(parts[0], 'base64url'));
    payload = JSON.parse(Buffer.from(parts[1], 'base64url'));
  } catch {
    throw new AuthError('malformed token');
  }
  if (header.alg !== 'RS256') throw new AuthError('unexpected algorithm');
  const jwk = (jwks?.keys ?? []).find((k) => k.kid === header.kid);
  if (!jwk) throw new AuthError('unknown key');
  const ok = verify('sha256', Buffer.from(`${parts[0]}.${parts[1]}`), createPublicKey({ key: jwk, format: 'jwk' }),
    Buffer.from(parts[2], 'base64url'));
  if (!ok) throw new AuthError('bad signature');
  if (!GOOGLE_ISSUERS.has(payload.iss)) throw new AuthError('wrong issuer');
  if (!audiences.includes(payload.aud)) throw new AuthError('wrong audience');
  const t = now / 1000;
  // A minute of leeway for clock drift.
  if (typeof payload.exp !== 'number' || payload.exp < t - 60) throw new AuthError('expired');
  if (typeof payload.iat === 'number' && payload.iat > t + 60) throw new AuthError('issued in the future');
  if (!payload.sub) throw new AuthError('no subject');
  return {
    sub: `${payload.sub}`,
    email: payload.email ? `${payload.email}` : null,
    emailVerified: payload.email_verified === true || payload.email_verified === 'true',
    name: payload.name ? `${payload.name}`.slice(0, 200) : null,
  };
}

/** Google's keys, cached for as long as Google's Cache-Control says (default one hour). */
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
  return {
    userId: `google:${profile.sub}`,
    provider: 'google',
    email: profile.email,
    name: profile.name,
    lastSeenAt: now.toISOString(),
  };
}
