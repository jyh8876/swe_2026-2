# Vinylo server (AWS)

One Lambda function behind a Function URL and one DynamoDB table. What it keeps follows the
privacy policy draft (Notion, week of 11/19):

| Kept | Fields |
|---|---|
| users | userId, provider, providerSub (Google or Apple id), email, nickname, country, age14Confirmed, termsAgreedAt, createdAt, lastLoginAt |
| songs | songId, title, artist, appleMusicId or isrc, artworkUrl (Apple Music / Spotify image URL only), addedAt |
| quiz progress | songId, level 1 to 5, best score, completedAt |
| conquered | songId, conqueredAt, bonusCoinGiven |
| coin ledger | change, reason (daily / conquer / upload / purchase), songId, createdAt; balance and last refill on the user |
| purchases | productId, purchaseToken, orderId, platform, status, purchasedAt, acknowledged |
| entitlements | unlimitedUpload, unlimitedExpiresAt (subscriptions) on the user |
| AI translation reports | title, artist, line number, reason, comment, engine, model, prompt version, language |

**Never kept:** lyrics, translations, quiz questions (they contain lyrics), covers the user
picked, the Gemini API key, card details. The server refuses bodies with `lyrics`, `lines`,
`text` or `original` fields.

## Routes

Every `/v1` call sends `Authorization: Bearer <token>`. Signing in (`POST /v1/me`) takes a
Google ID token or an Apple identity token and returns a **Vinylo session token** (30 days);
the other calls take the session token (or a fresh Google/Apple token).

| Route | What it does |
|---|---|
| `POST /v1/me` | Sign in. Body (all optional): `name` (Apple gives it once), `nickname`, `country` (2 letters), `age14Confirmed`, `termsAgreed: true`. Returns `{user, session: {token, expiresAt}}` |
| `GET /v1/me` | The user |
| `PATCH /v1/me` | Change `nickname`, `country`, `age14Confirmed`, `termsAgreed` |
| `DELETE /v1/me` | Deletes everything of the user (App Store 5.1.1(v)). Apple: body `{authorizationCode}` so Apple tokens are revoked |
| `GET /v1/sync` | Everything of the user at once (restore on a new phone) |
| `PUT /v1/songs/{songId}` | Song metadata: `title`, `artist`, `appleMusicId`, `isrc`, `artworkUrl`, `addedAt` |
| `DELETE /v1/songs/{songId}` | Removes the song |
| `PUT /v1/quiz/{songId}/{level}` | `{score, completedAt}`; the best score is kept |
| `PUT /v1/conquered/{songId}` | Conquered; the first time also gives the bonus coin |
| `DELETE /v1/conquered/{songId}` | Un-conquer (conquering again gives no second bonus) |
| `GET /v1/coins` | Balance, last refill, unlimited flag, last 50 ledger entries |
| `POST /v1/coins/daily` | Daily coin, once per day (midnight Korean time); 409 when already given |
| `POST /v1/coins/spend` | `{reason: "upload", songId}`: −1 coin, free while unlimited; 402 when the balance is 0 |
| `POST /v1/purchases` | `{platform: "android", productId, purchaseToken}`: checked with Google Play, acknowledged, granted once; 202 while pending, 409 if the token belongs to another account |
| `POST /v1/reports` | AI translation report: `{reason: wrong/awkward/offensive/reading/other, title, artist, lineIndex, comment, engine, model, promptVersion, targetLanguage, appVersion}` |
| `GET /apple-music/token` | Apple Music developer token for the Android app |
| `GET /health` | Liveness check |

Errors are `{"error": "..."}` with 400 (bad input), 401 (token), 402 (no coins), 404, 409, 503
(not configured).

The coin amounts are in `COIN` in `src/core.mjs` (daily +1, conquer +1, upload −1). The daily
coin only fills the balance up to `DAILY_COIN_CAP` (3); past that `POST /v1/coins/daily` answers
409 with `full: true`. Coins from conquering or purchases are not capped. Ad rewards
(`ad`) are not accepted until ad-network verification exists. Apple in-app purchases answer
501 until App Store Server API checks are added.

## Cost

About $0 a month at small scale:

- Lambda arm64, 128 MB: the always-free tier covers 1M requests a month.
- Function URL instead of API Gateway or a load balancer: no extra charge, HTTPS included.
- One DynamoDB table, provisioned 25 read / 25 write units: the always-free limit (it is per
  account and region, so keep this the only provisioned table). No backups (PITR), streams or
  indexes.
- SSM Parameter Store standard parameters: free.
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
2. Fill in `deploy.env` (gitignored): Team ID, MusicKit key ID and `.p8` path,
   `APPLE_CLIENT_IDS` (default `com.vinylo.ios`), the Google web client ID, and optionally:
   - **Sign in with Apple key** (`SIWA_KEY_ID`, `SIWA_P8`): Apple Developer → Keys → + →
     "Sign in with Apple" → primary App ID `com.vinylo.ios`. Without it accounts are still
     deleted, but Apple tokens are not revoked.
   - **Google Play service account** (`PLAY_SA_JSON`) and product IDs (`COIN_PRODUCTS`,
     `UNLIMITED_PRODUCTS`, `UNLIMITED_SUBSCRIPTIONS`) for purchases.
3. `./deploy.sh` prints the URL and checks `/health`. Run it again after any change. The session
   secret is generated on the first run and stays in SSM.

Keys go from the local files straight into SSM; they are never printed, committed or put in the
app.

## Test

```
node --test test/*.test.mjs
```

`test/handler.test.mjs` runs the handler end to end with in-memory stand-ins for DynamoDB (it
evaluates the update and condition expressions), SSM and the network (`test/stubs/`).
