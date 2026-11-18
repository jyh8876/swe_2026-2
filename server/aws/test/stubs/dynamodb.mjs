// In-memory stand-in for the three DynamoDB calls the handler makes.
export const table = new Map();
export class UpdateItemCommand { constructor(i) { this.input = i; } }
export class GetItemCommand { constructor(i) { this.input = i; } }
export class DeleteItemCommand { constructor(i) { this.input = i; } }
export class DynamoDBClient {
  async send(cmd) {
    const key = cmd.input.Key.userId.S;
    if (cmd instanceof GetItemCommand) return { Item: table.get(key) };
    if (cmd instanceof DeleteItemCommand) { table.delete(key); return {}; }
    // UpdateItem: apply "SET a = :x, b = if_not_exists(b, :y)".
    const item = { userId: { S: key }, ...(table.get(key) ?? {}) };
    const names = cmd.input.ExpressionAttributeNames ?? {};
    for (const part of cmd.input.UpdateExpression.replace(/^SET /, '').split(/, (?![^(]*\))/)) {
      const [lhs, rhs] = part.split(' = ');
      const attr = names[lhs] ?? lhs;
      const m = /^if_not_exists\(\w+, (:\w+)\)$/.exec(rhs);
      if (m) { if (!item[attr]) item[attr] = cmd.input.ExpressionAttributeValues[m[1]]; } else item[attr] = cmd.input.ExpressionAttributeValues[rhs];
    }
    table.set(key, item);
    return { Attributes: item };
  }
}
