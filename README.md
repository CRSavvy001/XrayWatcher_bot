 # Xray watcher bot

Telegram bot that watches Pons V2 token addresses using the open-source
xray-terminal CLI and alerts you when holders' avg PnL >= 15% and winrate >= 55%.

Commands: /watch, /unwatch, /watching, /check, /raw, /id

## Deploy (Railway)
1. Create a Telegram bot with @BotFather, copy the token.
2. Upload these files to a new GitHub repo: bot.mjs, package.json, Dockerfile, .gitignore.
3. Railway > New Project > Deploy from GitHub repo (it detects the Dockerfile).
4. Variables: BOT_TOKEN (required), ALLOWED_USER_IDS (recommended), others optional (see .env.example).
5. Add a Volume mounted at /data so your watchlist survives redeploys.
6. Run only ONE instance of the bot.

## First-run check
Send /raw 0xSOMETOKEN. The caption shows which JSON fields were detected for
avg PnL and winrate. If wrong or NOT FOUND, set PNL_KEY / WINRATE_KEY.
If values look like 0.15 instead of 15, set PNL_SCALE=100 / WINRATE_SCALE=100.
