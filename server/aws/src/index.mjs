// Vinylo account server: AWS Lambda behind a Function URL (payload format 2.0).
//   GET    /apple-music/token  Apple Music developer token for the Android app
//   POST   /v1/me              sign in: verifies the Google or Apple ID token, creates or updates
//                              the user. Body (optional): {"name": "..."} (Apple gives it once)
//   GET    /v1/me              the signed-in user's record
//   DELETE /v1/me              deletes the user's record (account deletion). Body for Apple:
//                              {"authorizationCode": "..."} so the Apple tokens are revoked
//   GET    /health             liveness check
// Every /v1/me call sends "Authorization: Bearer <ID token>" (Google ID token or Apple identity
// token). Stores users only (id, provider, email, name, timestamps); lyrics never reach it.
// Only the AWS SDK built into the Lambda Node.js runtime is used, so the zip is just this folder.
import { DynamoDBClient, UpdateItemCommand, GetItemCommand, DeleteItemCommand } from '@aws-sdk/client-dynamodb';
import { SSMClient, GetParameterCommand } from '@aws-sdk/client-ssm';
import {
  appleClientSecret, appleMusicToken, AuthError, JwksCache, revokeAppleTokens, TokenCache, tokenProvider, userRecord,
  verifyIdToken,
} from './core.mjs';

const env = process.env;
const ddb = new DynamoDBClient({});
const ssm = new SSMClient({});
const list = (v) => `${v ?? ''}`.split(',').map((s) => s.trim()).filter(Boolean);

async function secret(name) {
  const out = await ssm.send(new GetParameterCommand({ Name: name, WithDecryption: true }));
  return out.Parameter?.Value;
}

// ── Apple Music ──
let tokens = null;
async function musicTokens() {
  if (tokens) return tokens;
  const p8 = await secret(env.MUSICKIT_P8_PARAM);
  tokens = new TokenCache((now) => appleMusicToken({ p8, teamId: env.TEAM_ID, keyId: env.MUSICKIT_KEY_ID, now }));
  return tokens;
}

// ── Sign-in providers ──
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

async function signedInUser(headers) {
  const m = /^Bearer\s+(.+)$/i.exec(headers?.authorization ?? '');
  if (!m) return { error: reply(401, { error: 'missing token' }) };
  try {
    const provider = tokenProvider(m[1]);
    const p = providers[provider];
    if (!p) return { error: reply(401, { error: 'unknown issuer' }) };
    if (p.audiences.length === 0) return { error: reply(503, { error: `${provider} sign-in is not configured` }) };
    return { profile: verifyIdToken(m[1], { provider, jwks: await p.jwks.get(), audiences: p.audiences }), audience: p.audiences };
  } catch (e) {
    if (e instanceof AuthError) return { error: reply(401, { error: e.message }) };
    throw e;
  }
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

// ── Users ──
const s = (v) => (v == null ? { NULL: true } : { S: `${v}` });
const plain = (item) => item && Object.fromEntries(Object.entries(item).map(([k, v]) => [k, v.S ?? null]));

async function upsertUser(profile, nameFromApp) {
  const u = userRecord(profile);
  // Apple sends the name and email only on the first sign-in; later sign-ins keep what is stored.
  const name = u.name ?? (nameFromApp ? `${nameFromApp}`.slice(0, 200) : null);
  const sets = ['provider = :p', 'lastSeenAt = :t', 'createdAt = if_not_exists(createdAt, :t)'];
  const values = { ':p': s(u.provider), ':t': s(u.lastSeenAt) };
  if (u.email) { sets.push('email = :e'); values[':e'] = s(u.email); }
  if (name) { sets.push('#n = :n'); values[':n'] = s(name); }
  const out = await ddb.send(new UpdateItemCommand({
    TableName: env.USERS_TABLE,
    Key: { userId: { S: u.userId } },
    UpdateExpression: `SET ${sets.join(', ')}`,
    ...(name ? { ExpressionAttributeNames: { '#n': 'name' } } : {}),
    ExpressionAttributeValues: values,
    ReturnValues: 'ALL_NEW',
  }));
  return plain(out.Attributes);
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
  try {
    const text = event.isBase64Encoded ? Buffer.from(event.body, 'base64').toString() : event.body;
    const j = JSON.parse(text);
    return j && typeof j === 'object' ? j : {};
  } catch {
    return {};
  }
}

export async function handler(event) {
  const method = event.requestContext?.http?.method ?? 'GET';
  const path = (event.rawPath ?? '/').replace(/\/+$/, '') || '/';
  try {
    if (path === '/health' && method === 'GET') return reply(200, { ok: true });

    if (path === '/apple-music/token' && method === 'GET') {
      const { token, expiresAt } = (await musicTokens()).get();
      return reply(200, { token, expiresAt });
    }

    if (path === '/v1/me') {
      const { profile, error } = await signedInUser(event.headers);
      if (error) return error;
      const userId = userRecord(profile).userId;
      const body = jsonBody(event);
      if (method === 'POST') return reply(200, await upsertUser(profile, body.name));
      if (method === 'GET') {
        const out = await ddb.send(new GetItemCommand({ TableName: env.USERS_TABLE, Key: { userId: { S: userId } } }));
        return out.Item ? reply(200, plain(out.Item)) : reply(404, { error: 'not registered' });
      }
      if (method === 'DELETE') {
        let revoked = false;
        if (profile.provider === 'apple') {
          // The bundle ID the token was issued to is the client ID for Apple's endpoints.
          revoked = await revokeApple(body.authorizationCode, list(env.APPLE_CLIENT_IDS)[0]);
        }
        await ddb.send(new DeleteItemCommand({ TableName: env.USERS_TABLE, Key: { userId: { S: userId } } }));
        return reply(200, { deleted: true, appleTokensRevoked: revoked });
      }
      return reply(405, { error: 'method not allowed' });
    }
    return reply(404, { error: 'not found' });
  } catch (e) {
    // Details go to CloudWatch only (never tokens or keys).
    console.error(path, method, e?.name, e?.message);
    return reply(500, { error: 'server error' });
  }
}
