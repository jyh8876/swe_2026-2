# Vinylo account server (AWS)

A single Lambda function behind a Function URL. It keeps **users only**: account id, provider,
email, name, `createdAt`, `lastSeenAt`. Lyrics, songs, translations and listening history never
reach it.

| Endpoint | What it does |
|---|---|
| `GET /apple-music/token` | Apple Music developer token for the Android app (ES256, 30 days, re-issued 7 days before expiry) |
| `POST /v1/me` | Sign in: `Authorization: Bearer <Google ID token or Apple identity token>`, creates or updates the user. Body `{"name"}` (Apple sends the name once) |
| `GET /v1/me` | The signed-in user's record |
| `DELETE /v1/me` | Deletes the user's record (account deletion, App Store 5.1.1(v)). Apple: body `{"authorizationCode"}`, and the Apple tokens are revoked when a Sign in with Apple key is set |
| `GET /health` | Liveness check |

## Cost

Designed to stay at about $0 a month at small scale:

- Lambda arm64, 128 MB: the always-free tier covers 1M requests a month.
- Function URL instead of API Gateway or a load balancer: no extra charge, HTTPS included.
- DynamoDB, provisioned 1 read / 1 write unit: inside the always-free 25/25. No backups (PITR) or streams.
- SSM Parameter Store standard parameter: free.
- CloudWatch logs kept 7 days; only errors are logged.
- Reserved concurrency 5, when the account allows it, caps the bill if someone floods the URL.

Set a budget alarm once (Billing → Budgets → "Zero spend budget", free) so any charge emails you.

## Deploy

1. Install the AWS CLI v2 and sign in:
   ```
   curl -sSfL -o /tmp/awscliv2.zip https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip
   unzip -q -o /tmp/awscliv2.zip -d /tmp && /tmp/aws/install -i ~/.local/aws-cli -b ~/.local/bin
   aws configure          # access key of an IAM user (not the root account), region ap-northeast-2
   ```
2. Fill in `deploy.env` (gitignored): Team ID, MusicKit key ID, path to the MusicKit `.p8`,
   `APPLE_CLIENT_IDS` (bundle ID, default `com.vinylo.ios`), and later the Google web client ID.
   For Apple account deletion, also a **Sign in with Apple key** (`SIWA_KEY_ID`, `SIWA_P8`):
   Apple Developer → Keys → + → enable "Sign in with Apple" → configure with the primary App ID
   `com.vinylo.ios`. Without it accounts are still deleted, but Apple tokens are not revoked.
3. `./deploy.sh` prints the URL and checks `/health`. Run it again after any change.

The `.p8` goes from the local file straight into SSM; it is never printed, committed or put in
the app.

## Test

```
node --test test/*.test.mjs
```

`test/handler.test.mjs` runs the Lambda handler end to end with in-memory stand-ins for
DynamoDB, SSM and the network (`test/stubs/`).
