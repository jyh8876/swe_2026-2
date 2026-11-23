export const params = new Map();
export class GetParameterCommand { constructor(i) { this.input = i; } }
export class SSMClient { async send(cmd) { return { Parameter: { Value: params.get(cmd.input.Name) } }; } }
