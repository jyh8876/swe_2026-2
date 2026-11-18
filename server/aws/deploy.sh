#!/usr/bin/env bash
# Deploys the Vinylo account server to AWS at (near) zero cost:
#   Lambda (Node.js 22, arm64, 128 MB) + Function URL (HTTPS, no domain or load balancer)
#   DynamoDB users table, provisioned 1 RCU / 1 WCU (inside the always-free 25/25)
#   SSM Parameter Store standard SecureString for the MusicKit .p8 (free)
#   CloudWatch logs kept 7 days
# Safe to run again: existing resources are updated, not duplicated.
#
# Settings come from deploy.env next to this script (gitignored), or the environment:
#   AWS_REGION        default ap-northeast-2 (Seoul)
#   TEAM_ID           Apple Team ID
#   MUSICKIT_KEY_ID   MusicKit key ID
#   MUSICKIT_P8       path to the MusicKit .p8 (read by the AWS CLI, never printed)
#   GOOGLE_CLIENT_IDS comma-separated Google OAuth client IDs (web client); blank = Google off
#   APPLE_CLIENT_IDS  bundle IDs for Sign in with Apple (default com.vinylo.ios)
#   SIWA_KEY_ID, SIWA_P8  Sign in with Apple key (optional): needed to revoke Apple tokens on
#                     account deletion, as App Store guideline 5.1.1(v) requires
set -euo pipefail
cd "$(dirname "$0")"
[ -f deploy.env ] && . ./deploy.env

REGION="${AWS_REGION:-ap-northeast-2}"
NAME="${NAME:-vinylo-api}"
TABLE="${TABLE:-vinylo-users}"
PARAM="${PARAM:-/vinylo/musickit-p8}"
: "${TEAM_ID:?set TEAM_ID}" "${MUSICKIT_KEY_ID:?set MUSICKIT_KEY_ID}" "${MUSICKIT_P8:?set MUSICKIT_P8}"
GOOGLE_CLIENT_IDS="${GOOGLE_CLIENT_IDS:-}"
APPLE_CLIENT_IDS="${APPLE_CLIENT_IDS:-com.vinylo.ios}"
SIWA_KEY_ID="${SIWA_KEY_ID:-}"
SIWA_P8="${SIWA_P8:-}"
SIWA_PARAM="${SIWA_PARAM:-/vinylo/siwa-p8}"
export AWS_REGION="$REGION" AWS_PAGER=""

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
echo "account $ACCOUNT, region $REGION"

echo "1/6 MusicKit key -> SSM $PARAM (SecureString, standard tier)"
aws ssm put-parameter --name "$PARAM" --type SecureString --tier Standard --overwrite \
  --value "file://$MUSICKIT_P8" >/dev/null
if [ -n "$SIWA_KEY_ID" ] && [ -n "$SIWA_P8" ]; then
  echo "    Sign in with Apple key -> SSM $SIWA_PARAM"
  aws ssm put-parameter --name "$SIWA_PARAM" --type SecureString --tier Standard --overwrite \
    --value "file://$SIWA_P8" >/dev/null
else
  SIWA_KEY_ID=""   # no key: accounts are deleted, but Apple tokens are not revoked
fi

echo "2/6 DynamoDB table $TABLE"
if ! aws dynamodb describe-table --table-name "$TABLE" >/dev/null 2>&1; then
  aws dynamodb create-table --table-name "$TABLE" \
    --attribute-definitions AttributeName=userId,AttributeType=S \
    --key-schema AttributeName=userId,KeyType=HASH \
    --billing-mode PROVISIONED --provisioned-throughput ReadCapacityUnits=1,WriteCapacityUnits=1 \
    --deletion-protection-enabled >/dev/null
  aws dynamodb wait table-exists --table-name "$TABLE"
fi

echo "3/6 IAM role $NAME-role (logs, this table, these parameters only)"
ROLE_ARN="arn:aws:iam::$ACCOUNT:role/$NAME-role"
if ! aws iam get-role --role-name "$NAME-role" >/dev/null 2>&1; then
  aws iam create-role --role-name "$NAME-role" --assume-role-policy-document '{
    "Version":"2012-10-17",
    "Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  NEW_ROLE=1
fi
aws iam put-role-policy --role-name "$NAME-role" --policy-name "$NAME-policy" --policy-document "{
  \"Version\":\"2012-10-17\",
  \"Statement\":[
    {\"Effect\":\"Allow\",\"Action\":[\"logs:CreateLogStream\",\"logs:PutLogEvents\"],
     \"Resource\":\"arn:aws:logs:$REGION:$ACCOUNT:log-group:/aws/lambda/$NAME:*\"},
    {\"Effect\":\"Allow\",\"Action\":[\"dynamodb:GetItem\",\"dynamodb:UpdateItem\",\"dynamodb:DeleteItem\"],
     \"Resource\":\"arn:aws:dynamodb:$REGION:$ACCOUNT:table/$TABLE\"},
    {\"Effect\":\"Allow\",\"Action\":\"ssm:GetParameter\",
     \"Resource\":[\"arn:aws:ssm:$REGION:$ACCOUNT:parameter$PARAM\",\"arn:aws:ssm:$REGION:$ACCOUNT:parameter$SIWA_PARAM\"]}]}"
# A new role takes a few seconds before Lambda can use it.
[ "${NEW_ROLE:-0}" = 1 ] && sleep 12

echo "4/6 log group, kept 7 days"
aws logs create-log-group --log-group-name "/aws/lambda/$NAME" 2>/dev/null || true
aws logs put-retention-policy --log-group-name "/aws/lambda/$NAME" --retention-in-days 7

echo "5/6 Lambda function $NAME"
ZIP="$(mktemp -d)/function.zip"
(cd src && zip -q -r "$ZIP" .)
ENVJSON="{\"Variables\":{\"TEAM_ID\":\"$TEAM_ID\",\"MUSICKIT_KEY_ID\":\"$MUSICKIT_KEY_ID\",\"MUSICKIT_P8_PARAM\":\"$PARAM\",\"USERS_TABLE\":\"$TABLE\",\"GOOGLE_CLIENT_IDS\":\"$GOOGLE_CLIENT_IDS\",\"APPLE_CLIENT_IDS\":\"$APPLE_CLIENT_IDS\",\"SIWA_KEY_ID\":\"$SIWA_KEY_ID\",\"SIWA_P8_PARAM\":\"$SIWA_PARAM\"}}"
if aws lambda get-function --function-name "$NAME" >/dev/null 2>&1; then
  aws lambda update-function-code --function-name "$NAME" --zip-file "fileb://$ZIP" >/dev/null
  aws lambda wait function-updated --function-name "$NAME"
  aws lambda update-function-configuration --function-name "$NAME" --environment "$ENVJSON" >/dev/null
else
  aws lambda create-function --function-name "$NAME" --runtime nodejs22.x --architectures arm64 \
    --handler index.handler --role "$ROLE_ARN" --memory-size 128 --timeout 10 \
    --zip-file "fileb://$ZIP" --environment "$ENVJSON" >/dev/null
fi
aws lambda wait function-updated --function-name "$NAME"
# Caps runaway cost from abuse. New accounts often cannot reserve concurrency; then it is skipped.
aws lambda put-function-concurrency --function-name "$NAME" --reserved-concurrent-executions 5 >/dev/null 2>&1 \
  || echo "   (reserved concurrency not available on this account; skipped)"

echo "6/6 public HTTPS URL"
if ! URL="$(aws lambda get-function-url-config --function-name "$NAME" --query FunctionUrl --output text 2>/dev/null)"; then
  URL="$(aws lambda create-function-url-config --function-name "$NAME" --auth-type NONE --query FunctionUrl --output text)"
  aws lambda add-permission --function-name "$NAME" --statement-id public-url \
    --action lambda:InvokeFunctionUrl --principal '*' --function-url-auth-type NONE >/dev/null
  # Newer accounts also need InvokeFunction for calls that come through the URL.
  aws lambda add-permission --function-name "$NAME" --statement-id public-url-invoke \
    --action lambda:InvokeFunction --principal '*' --invoked-via-function-url >/dev/null 2>&1 || true
fi
echo "URL: $URL"
echo "health: $(curl -s "${URL%/}/health")"
