// Vinylo account server: AWS Lambda behind a Function URL (payload format 2.0).
//   GET    /apple-music/token  Apple Music developer token for the Android app
//   POST   /v1/me              sign in: verifies the Google ID token, creates or updates the user
//   GET    /v1/me              the signed-in user's record
//   DELETE /v1/me              deletes the user's record (account deletion)
//   GET    /health             liveness check
// Stores users only (id, email, name, timestamps). Lyrics and songs never reach this server.
// Only the AWS SDK built into the Lambda Node.js runtime is used, so the zip is just this folder.
import { DynamoDBClient, UpdateItemCommand, GetItemCommand, DeleteItemCommand } from '@aws-sdk/client-dynamodb';
import { SSMClient, GetParameterCommand } from '@aws-sdk/client-ssm';
import { appleMusicToken, AuthError, JwksCache, TokenCache, userRecord, verifyGoogleIdToken } from './core.mjs';

const env = process.env;
const ddb = new DynamoDBClient({});
const ssm = new SSMClient({});

// ── Apple Music ──
let tokens = null;
async function musicTokens() {
  if (tokens) return tokens;
  const out = await ssm.send(new GetParameterCommand({ Name: env.MUSICKIT_P8_PARAM, WithDecryption: true }));
  const p8 = out.Parameter?.Value;
  tokens = new TokenCache((now) => appleMusicToken({ p8, teamId: env.TEAM_ID, keyId: env.MUSICKIT_KEY_ID, now }));
  return tokens;
}

// ── Google sign-in ──
const audiences = `${env.GOOGLE_CLIENT_IDS ?? ''}`.split(',').map((s) => s.trim()).filter(Boolean);
const jwks = new JwksCache(async () => {
  const r = await fetch('https://www.googleapis.com/oauth2/v3/certs');
  if (!r.ok) throw new Error(`Google keys: HTTP ${r.status}`);
  const maxAge = /max-age=(\d+)/.exec(r.headers.get('cache-control') ?? '')?.[1];
  return { keys: await r.json(), maxAgeSeconds: maxAge ? Number(maxAge) : 3600 };
});

async function signedInUser(headers) {
  if (audiences.length === 0) return { error: reply(503, { error: 'sign-in is not configured' }) };
  const m = /^Bearer\s+(.+)$/i.exec(headers?.authorization ?? '');
  if (!m) return { error: reply(401, { error: 'missing token' }) };
  try {
    return { profile: verifyGoogleIdToken(m[1], { jwks: await jwks.get(), audiences }) };
  } catch (e) {
    if (e instanceof AuthError) return { error: reply(401, { error: e.message }) };
    throw e;
  }
}

const s = (v) => (v == null ? { NULL: true } : { S: `${v}` });
const plain = (item) => item && Object.fromEntries(Object.entries(item).map(([k, v]) => [k, v.S ?? null]));

async function upsertUser(profile) {
  const u = userRecord(profile);
  const out = await ddb.send(new UpdateItemCommand({
    TableName: env.USERS_TABLE,
    Key: { userId: { S: u.userId } },
    UpdateExpression: 'SET provider = :p, email = :e, #n = :n, lastSeenAt = :t, createdAt = if_not_exists(createdAt, :t)',
    ExpressionAttributeNames: { '#n': 'name' },
    ExpressionAttributeValues: { ':p': s(u.provider), ':e': s(u.email), ':n': s(u.name), ':t': s(u.lastSeenAt) },
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
      if (method === 'POST') return reply(200, await upsertUser(profile));
      if (method === 'GET') {
        const out = await ddb.send(new GetItemCommand({ TableName: env.USERS_TABLE, Key: { userId: { S: userId } } }));
        return out.Item ? reply(200, plain(out.Item)) : reply(404, { error: 'not registered' });
      }
      if (method === 'DELETE') {
        await ddb.send(new DeleteItemCommand({ TableName: env.USERS_TABLE, Key: { userId: { S: userId } } }));
        return reply(204, null);
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
