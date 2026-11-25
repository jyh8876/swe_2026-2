// DynamoDB access for the Vinylo server: one table, partition key "pk" (the user id) and sort key
// "sk" (what the item is). One table keeps everything inside the always-free 25 RCU / 25 WCU.
//
//   pk = <userId>          sk = profile                     user, coin balance, entitlements
//                          sk = song#<songId>                song metadata (no lyrics)
//                          sk = quiz#<songId>#<level>        best quiz score per level
//                          sk = conq#<songId>                conquered song, bonus coin given
//                          sk = coin#<time>#<rand>           coin ledger entry
//                          sk = purchase#<tokenHash>         store purchase
//                          sk = report#<time>#<rand>         pointer to a report (deleted with the user)
//   pk = ptoken#<hash>     sk = owner                        a purchase token can belong to one user only
//   pk = reports           sk = <time>#<rand>                AI translation reports
import {
  BatchWriteItemCommand, DeleteItemCommand, DynamoDBClient, GetItemCommand, PutItemCommand, QueryCommand,
  TransactWriteItemsCommand, UpdateItemCommand,
} from '@aws-sdk/client-dynamodb';
import { randomBytes } from 'node:crypto';

const ddb = new DynamoDBClient({});
const table = () => process.env.DATA_TABLE;

// ── Attribute values (only the types this server uses) ──
export function toAttr(v) {
  if (v == null) return { NULL: true };
  if (typeof v === 'boolean') return { BOOL: v };
  if (typeof v === 'number') return { N: `${v}` };
  return { S: `${v}` };
}
export function fromAttr(a) {
  if ('S' in a) return a.S;
  if ('N' in a) return Number(a.N);
  if ('BOOL' in a) return a.BOOL;
  return null;
}
const toItem = (o) => Object.fromEntries(Object.entries(o).filter(([, v]) => v !== undefined).map(([k, v]) => [k, toAttr(v)]));
export const fromItem = (item) => item && Object.fromEntries(Object.entries(item).map(([k, v]) => [k, fromAttr(v)]));
const key = (pk, sk) => ({ pk: { S: pk }, sk: { S: sk } });
const stamp = (now) => `${new Date(now).toISOString()}#${randomBytes(3).toString('hex')}`;

/** "SET a = :a, b = :b" for the given fields; names go through #placeholders. */
function setExpr(fields, extra = []) {
  const names = {}, values = {}, sets = [...extra];
  for (const [k, v] of Object.entries(fields)) {
    if (v === undefined) continue;
    names[`#${k}`] = k;
    values[`:${k}`] = toAttr(v);
    sets.push(`#${k} = :${k}`);
  }
  return { names, values, expr: `SET ${sets.join(', ')}` };
}

export class ConditionFailed extends Error {}
async function send(cmd) {
  try {
    return await ddb.send(cmd);
  } catch (e) {
    if (e?.name === 'ConditionalCheckFailedException' || e?.name === 'TransactionCanceledException') throw new ConditionFailed(e.name);
    throw e;
  }
}

// ── Profile ──

export async function getProfile(userId) {
  return fromItem((await send(new GetItemCommand({ TableName: table(), Key: key(userId, 'profile') }))).Item);
}

/**
 * Sign-in: creates the profile or refreshes it. [fields] never overwrite a stored value with null
 * (Apple sends the email and name only once).
 */
export async function upsertProfile(userId, fields, now) {
  const t = new Date(now).toISOString();
  const keep = Object.fromEntries(Object.entries(fields).filter(([, v]) => v != null));
  const { names, values, expr } = setExpr({ ...keep, lastLoginAt: t }, [
    '#createdAt = if_not_exists(#createdAt, :t)',
    '#coinBalance = if_not_exists(#coinBalance, :zero)',
  ]);
  Object.assign(names, { '#createdAt': 'createdAt', '#coinBalance': 'coinBalance' });
  Object.assign(values, { ':t': toAttr(t), ':zero': toAttr(0) });
  const out = await send(new UpdateItemCommand({
    TableName: table(), Key: key(userId, 'profile'), UpdateExpression: expr,
    ExpressionAttributeNames: names, ExpressionAttributeValues: values, ReturnValues: 'ALL_NEW',
  }));
  return fromItem(out.Attributes);
}

/** Changes profile fields the user may edit; the profile must exist. */
export async function updateProfile(userId, fields) {
  if (Object.keys(fields).length === 0) return getProfile(userId);
  const { names, values, expr } = setExpr(fields);
  const out = await send(new UpdateItemCommand({
    TableName: table(), Key: key(userId, 'profile'), UpdateExpression: expr, ConditionExpression: 'attribute_exists(pk)',
    ExpressionAttributeNames: names, ExpressionAttributeValues: values, ReturnValues: 'ALL_NEW',
  }));
  return fromItem(out.Attributes);
}

// ── Everything of one user ──

export async function allItems(pk, prefix) {
  const items = [];
  let start;
  do {
    const out = await send(new QueryCommand({
      TableName: table(),
      KeyConditionExpression: prefix ? 'pk = :pk AND begins_with(sk, :sk)' : 'pk = :pk',
      ExpressionAttributeValues: { ':pk': { S: pk }, ...(prefix ? { ':sk': { S: prefix } } : {}) },
      ExclusiveStartKey: start,
    }));
    items.push(...out.Items.map(fromItem));
    start = out.LastEvaluatedKey;
  } while (start);
  return items;
}

/** Deletes every item of the user, their reports and their purchase-token markers. */
export async function deleteUser(userId) {
  const items = await allItems(userId);
  const keys = items.map((i) => [userId, i.sk]);
  for (const i of items) {
    if (i.sk.startsWith('report#')) keys.push(['reports', i.sk.slice('report#'.length)]);
    if (i.sk.startsWith('purchase#')) keys.push([`ptoken#${i.sk.slice('purchase#'.length)}`, 'owner']);
  }
  for (let n = 0; n < keys.length; n += 25) {
    let req = { [table()]: keys.slice(n, n + 25).map(([pk, sk]) => ({ DeleteRequest: { Key: key(pk, sk) } })) };
    // Unprocessed deletes are retried a few times (throttling on 1 WCU).
    for (let tries = 0; req && Object.keys(req).length && tries < 8; tries++) {
      if (tries) await new Promise((r) => setTimeout(r, 200 * tries));
      const out = await send(new BatchWriteItemCommand({ RequestItems: req }));
      req = out.UnprocessedItems && Object.keys(out.UnprocessedItems).length ? out.UnprocessedItems : null;
    }
    if (req) throw new Error('delete did not finish');
  }
  return keys.length;
}

// ── Songs, quiz, conquered ──

export async function putSong(userId, songId, song, now) {
  const item = { pk: userId, sk: `song#${songId}`, songId, ...song, addedAt: song.addedAt ?? new Date(now).toISOString() };
  await send(new PutItemCommand({ TableName: table(), Item: toItem(item) }));
  return fromItem(toItem(item));
}

export async function deleteSong(userId, songId) {
  await send(new DeleteItemCommand({ TableName: table(), Key: key(userId, `song#${songId}`) }));
}

/** Keeps the best score of a level; returns the stored record. */
export async function putQuiz(userId, songId, { level, score, completedAt }, now) {
  const at = completedAt ?? new Date(now).toISOString();
  try {
    const out = await send(new UpdateItemCommand({
      TableName: table(), Key: key(userId, `quiz#${songId}#${level}`),
      UpdateExpression: 'SET songId = :s, #level = :l, #score = :sc, completedAt = :at',
      ConditionExpression: 'attribute_not_exists(#score) OR #score < :sc',
      ExpressionAttributeNames: { '#level': 'level', '#score': 'score' },
      ExpressionAttributeValues: { ':s': toAttr(songId), ':l': toAttr(level), ':sc': toAttr(score), ':at': toAttr(at) },
      ReturnValues: 'ALL_NEW',
    }));
    return fromItem(out.Attributes);
  } catch (e) {
    if (e instanceof ConditionFailed) return fromItem((await send(new GetItemCommand({ TableName: table(), Key: key(userId, `quiz#${songId}#${level}`) }))).Item);
    throw e;
  }
}

// ── Coins ──

function ledgerPut(userId, change, reason, songId, now) {
  return { Put: { TableName: table(), Item: toItem({ pk: userId, sk: `coin#${stamp(now)}`, change, reason, songId: songId ?? null, createdAt: new Date(now).toISOString() }) } };
}
function balanceUpdate(userId, change, { condition, names = {}, values = {}, set = [] } = {}) {
  return {
    Update: {
      TableName: table(), Key: key(userId, 'profile'),
      UpdateExpression: `SET ${['coinBalance = coinBalance + :c', ...set].join(', ')}`,
      ConditionExpression: ['attribute_exists(pk)', condition].filter(Boolean).join(' AND '),
      ...(Object.keys(names).length ? { ExpressionAttributeNames: names } : {}),
      ExpressionAttributeValues: { ':c': toAttr(change), ...values },
    },
  };
}

/**
 * Gives the daily coin once per [day] while the balance is below [cap]; false when it was already
 * given that day or the balance is full.
 */
export async function claimDaily(userId, change, day, now, cap) {
  try {
    await send(new TransactWriteItemsCommand({
      TransactItems: [
        balanceUpdate(userId, change, {
          condition: '(attribute_not_exists(lastRefillDay) OR lastRefillDay <> :d) AND coinBalance < :cap',
          values: { ':d': toAttr(day), ':t': toAttr(new Date(now).toISOString()), ':cap': toAttr(cap) },
          set: ['lastRefillDay = :d', 'lastRefillAt = :t'],
        }),
        ledgerPut(userId, change, 'daily', null, now),
      ],
    }));
    return true;
  } catch (e) {
    if (e instanceof ConditionFailed) return false;
    throw e;
  }
}

/** Spends coins (change < 0); false when the balance is too low. */
export async function spendCoins(userId, change, reason, songId, now) {
  try {
    await send(new TransactWriteItemsCommand({
      TransactItems: [
        balanceUpdate(userId, change, { condition: 'coinBalance >= :need', values: { ':need': toAttr(-change) } }),
        ledgerPut(userId, change, reason, songId, now),
      ],
    }));
    return true;
  } catch (e) {
    if (e instanceof ConditionFailed) return false;
    throw e;
  }
}

/**
 * Marks a song conquered. The bonus coin is given the first time only: un-conquering keeps the
 * record (conqueredAt = null) so conquering again does not pay twice. Returns {bonus}.
 */
export async function conquer(userId, songId, bonus, at, now) {
  const k = key(userId, `conq#${songId}`);
  try {
    await send(new TransactWriteItemsCommand({
      TransactItems: [
        { Put: { TableName: table(), Item: toItem({ pk: userId, sk: `conq#${songId}`, songId, conqueredAt: at, bonusCoinGiven: true }), ConditionExpression: 'attribute_not_exists(pk)' } },
        balanceUpdate(userId, bonus),
        ledgerPut(userId, bonus, 'conquer', songId, now),
      ],
    }));
    return { bonus };
  } catch (e) {
    if (!(e instanceof ConditionFailed)) throw e;
    await send(new UpdateItemCommand({
      TableName: table(), Key: k, UpdateExpression: 'SET conqueredAt = :at', ConditionExpression: 'attribute_exists(pk)',
      ExpressionAttributeValues: { ':at': toAttr(at) },
    }));
    return { bonus: 0 };
  }
}

export async function unconquer(userId, songId) {
  try {
    await send(new UpdateItemCommand({
      TableName: table(), Key: key(userId, `conq#${songId}`), UpdateExpression: 'SET conqueredAt = :n',
      ConditionExpression: 'attribute_exists(pk)', ExpressionAttributeValues: { ':n': { NULL: true } },
    }));
  } catch (e) {
    if (!(e instanceof ConditionFailed)) throw e;
  }
}

// ── Purchases ──

/**
 * Records a verified purchase and what it grants, once per purchase token. [grant] is
 * {coins} for a coin pack or {unlimitedExpiresAt} (null = permanent) for unlimited uploads.
 * Returns 'new', 'updated' (same user, same token again) or 'taken' (token of another user).
 */
export async function recordPurchase(userId, purchase, grant, now, retry = true) {
  const hash = purchase.tokenHash;
  const owner = fromItem((await send(new GetItemCommand({ TableName: table(), Key: key(`ptoken#${hash}`, 'owner') }))).Item);
  if (owner && owner.userId !== userId) return 'taken';
  const record = { pk: userId, sk: `purchase#${hash}`, ...purchase, updatedAt: new Date(now).toISOString() };
  if (owner) {
    // Seen before: refresh status (e.g. a subscription renewed) without granting coins again.
    const items = [{ Put: { TableName: table(), Item: toItem(record) } }];
    if (grant.unlimited) items.push(unlimitedUpdate(userId, grant.unlimitedExpiresAt));
    await send(new TransactWriteItemsCommand({ TransactItems: items }));
    return 'updated';
  }
  const items = [
    { Put: { TableName: table(), Item: toItem({ pk: `ptoken#${hash}`, sk: 'owner', userId }), ConditionExpression: 'attribute_not_exists(pk)' } },
    { Put: { TableName: table(), Item: toItem(record) } },
  ];
  if (grant.coins) items.push(balanceUpdate(userId, grant.coins), ledgerPut(userId, grant.coins, 'purchase', null, now));
  if (grant.unlimited) items.push(unlimitedUpdate(userId, grant.unlimitedExpiresAt));
  try {
    await send(new TransactWriteItemsCommand({ TransactItems: items }));
    return 'new';
  } catch (e) {
    // Another request took the token in between: look again once.
    if (e instanceof ConditionFailed && retry) return recordPurchase(userId, purchase, grant, now, false);
    throw e;
  }
}

function unlimitedUpdate(userId, expiresAt) {
  return {
    Update: {
      TableName: table(), Key: key(userId, 'profile'),
      UpdateExpression: 'SET unlimitedUpload = :u, unlimitedExpiresAt = :e',
      ConditionExpression: 'attribute_exists(pk)',
      ExpressionAttributeValues: { ':u': toAttr(true), ':e': toAttr(expiresAt) },
    },
  };
}

// ── Reports ──

export async function putReport(userId, report, now) {
  const s = stamp(now);
  await send(new TransactWriteItemsCommand({
    TransactItems: [
      { Put: { TableName: table(), Item: toItem({ pk: 'reports', sk: s, userId, ...report, createdAt: new Date(now).toISOString(), status: 'open' }) } },
      { Put: { TableName: table(), Item: toItem({ pk: userId, sk: `report#${s}` }) } },
    ],
  }));
  return s;
}
