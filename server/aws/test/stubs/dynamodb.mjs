// In-memory stand-in for the DynamoDB calls the server makes. It evaluates the small expression
// grammar store.mjs uses (SET with if_not_exists and +, conditions with AND/OR, exists checks and
// comparisons), so conditional writes and transactions behave as they would on AWS.
export const table = new Map();
const k = (key) => `${key.pk.S}|${key.sk.S}`;

class Cmd { constructor(i) { this.input = i; } }
export class GetItemCommand extends Cmd {}
export class PutItemCommand extends Cmd {}
export class UpdateItemCommand extends Cmd {}
export class DeleteItemCommand extends Cmd {}
export class QueryCommand extends Cmd {}
export class BatchWriteItemCommand extends Cmd {}
export class TransactWriteItemsCommand extends Cmd {}

const fail = (name) => Object.assign(new Error(name), { name });
const val = (a) => (a == null || a.NULL ? undefined : 'N' in a ? Number(a.N) : 'S' in a ? a.S : a.BOOL);

/** Splits [s] on [sep] outside parentheses. */
function splitTop(s, sep) {
  const out = [];
  let depth = 0, last = 0;
  for (let i = 0; i < s.length; i++) {
    if (s[i] === '(') depth++;
    else if (s[i] === ')') depth--;
    else if (depth === 0 && s.startsWith(sep, i)) { out.push(s.slice(last, i)); last = i + sep.length; i += sep.length - 1; }
  }
  out.push(s.slice(last));
  return out.map((x) => x.trim());
}

/** Index of the parenthesis that closes the one at 0. */
function closes(s) {
  let depth = 0;
  for (let i = 0; i < s.length; i++) {
    if (s[i] === '(') depth++;
    if (s[i] === ')' && --depth === 0) return i;
  }
  return -1;
}

function cond(expr, item, names = {}, values = {}) {
  let e = expr.trim();
  // Drop parentheses that wrap the whole expression.
  while (e.startsWith('(') && closes(e) === e.length - 1) e = e.slice(1, -1).trim();
  const ors = splitTop(e, ' OR ');
  if (ors.length > 1) return ors.some((x) => cond(x, item, names, values));
  const ands = splitTop(e, ' AND ');
  if (ands.length > 1) return ands.every((x) => cond(x, item, names, values));
  const name = (n) => names[n] ?? n;
  let m;
  if ((m = /^attribute_exists\(([#\w]+)\)$/.exec(e))) return item?.[name(m[1])] !== undefined;
  if ((m = /^attribute_not_exists\(([#\w]+)\)$/.exec(e))) return item?.[name(m[1])] === undefined;
  if ((m = /^([#\w]+) (>=|<=|<>|<|>|=) (:\w+)$/.exec(e))) {
    const a = val(item?.[name(m[1])]), b = val(values[m[3]]);
    if (a === undefined) return m[2] === '<>';
    return { '>=': a >= b, '<=': a <= b, '<>': a !== b, '<': a < b, '>': a > b, '=': a === b }[m[2]];
  }
  throw new Error(`stub cannot evaluate: ${e}`);
}

function applyUpdate(input) {
  const id = k(input.Key);
  const item = { ...input.Key, ...(table.get(id) ?? {}) };
  const names = input.ExpressionAttributeNames ?? {}, values = input.ExpressionAttributeValues ?? {};
  for (const part of splitTop(input.UpdateExpression.replace(/^SET /, ''), ',')) {
    const [lhs, rhs] = part.split(' = ').map((x) => x.trim());
    const attr = names[lhs] ?? lhs;
    let m;
    if ((m = /^if_not_exists\(([#\w]+), (:\w+)\)$/.exec(rhs))) { if (item[attr] === undefined) item[attr] = values[m[2]]; }
    else if ((m = /^([#\w]+) \+ (:\w+)$/.exec(rhs))) item[attr] = { N: `${(val(item[names[m[1]] ?? m[1]]) ?? 0) + val(values[m[2]])}` };
    else item[attr] = values[rhs];
  }
  table.set(id, item);
  return item;
}

const check = (input, existing) => !input.ConditionExpression
  || cond(input.ConditionExpression, existing, input.ExpressionAttributeNames, input.ExpressionAttributeValues);

export class DynamoDBClient {
  async send(cmd) {
    const i = cmd.input;
    if (cmd instanceof GetItemCommand) return { Item: table.get(k(i.Key)) };
    if (cmd instanceof DeleteItemCommand) { table.delete(k(i.Key)); return {}; }
    if (cmd instanceof PutItemCommand) {
      if (!check(i, table.get(k(i.Item)))) throw fail('ConditionalCheckFailedException');
      table.set(k(i.Item), i.Item);
      return {};
    }
    if (cmd instanceof UpdateItemCommand) {
      if (!check(i, table.get(k(i.Key)))) throw fail('ConditionalCheckFailedException');
      return { Attributes: applyUpdate(i) };
    }
    if (cmd instanceof QueryCommand) {
      const pk = i.ExpressionAttributeValues[':pk'].S, pre = i.ExpressionAttributeValues[':sk']?.S ?? '';
      const items = [...table.values()].filter((x) => x.pk.S === pk && x.sk.S.startsWith(pre)).sort((a, b) => (a.sk.S < b.sk.S ? -1 : 1));
      return { Items: items };
    }
    if (cmd instanceof BatchWriteItemCommand) {
      for (const reqs of Object.values(i.RequestItems)) for (const r of reqs) table.delete(k(r.DeleteRequest.Key));
      return { UnprocessedItems: {} };
    }
    if (cmd instanceof TransactWriteItemsCommand) {
      for (const t of i.TransactItems) {
        const x = t.Put ?? t.Update ?? t.ConditionCheck;
        if (!check(x, table.get(k(x.Key ?? x.Item)))) throw fail('TransactionCanceledException');
      }
      for (const t of i.TransactItems) {
        if (t.Put) table.set(k(t.Put.Item), t.Put.Item);
        if (t.Update) applyUpdate(t.Update);
      }
      return {};
    }
    throw new Error('stub: unknown command');
  }
}
