# mvv42-uptime

External watchdog for [mvv42.ru](https://mvv42.ru): a GitHub Actions cron (every 10 min)
checks the public pages and health endpoints and the TLS certificate (≥ 14 days left),
and sends a Telegram message when the state changes (and a reminder every 3 h while
something is still down). It runs outside the server, so it also catches "the whole
VDS is down", which the on-server monitoring (mvv42-infra `monitoring/`) cannot report.

- Targets and thresholds: `check.sh`.
- Secrets: `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` (synced by mvv42-infra `scripts/sync-secrets.sh`).
- State between runs: Actions cache `uptime-state-*` (newest restored, older pruned).
- GitHub disables scheduled workflows after 60 days without repo activity; every run
  re-enables the workflow. If alerts ever stop, check the Actions tab first.
