// Test-only: points the AWS SDK imports at small in-memory stand-ins.
const stubs = {
  '@aws-sdk/client-dynamodb': new URL('./dynamodb.mjs', import.meta.url).href,
  '@aws-sdk/client-ssm': new URL('./ssm.mjs', import.meta.url).href,
};
export async function resolve(specifier, context, next) {
  return stubs[specifier] ? { url: stubs[specifier], shortCircuit: true } : next(specifier, context);
}
