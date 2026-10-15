#!/usr/bin/env bash
# External watchdog for mvv42.ru: runs on GitHub's runners (outside the VDS), so it
# also notices when the whole server is down - which the on-server monitoring can't.
#
# Checks every target, compares with the previous run (state/status, restored from
# the Actions cache) and sends ONE Telegram message when something changed
# (OK -> FAIL or FAIL -> OK), plus a reminder every 3 h while anything still fails.
#
# Env: TG_TOKEN, TG_CHAT (optional locally: without them the message is printed).
set -uo pipefail

STATE_DIR="${STATE_DIR:-state}"
STATE="$STATE_DIR/status"
REMIND_AFTER=$((3 * 3600))
CERT_MIN_DAYS=14
NOW="$(date +%s)"

# name url
TARGETS=(
  "portal https://mvv42.ru/"
  "auth https://mvv42.ru/auth/health"
  "cashpulse https://mvv42.ru/cashpulse/"
  "bonds https://mvv42.ru/bonds/health"
  "credit_calc https://mvv42.ru/credit_calc/api/health"
  "keysynth https://mvv42.ru/keysynth/health"
)

declare -A status detail
check_url() { # 3 attempts, 10 s apart: one lost packet on the runner is not an outage
  local url="$1" code i
  for i in 1 2 3; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$url")"
    [ "$code" = 200 ] && { echo 200; return 0; }
    [ "$i" -lt 3 ] && sleep 10
  done
  echo "${code:-000}"
  return 1
}

for t in "${TARGETS[@]}"; do
  name="${t%% *}"; url="${t#* }"
  if code="$(check_url "$url")"; then
    status[$name]=OK; detail[$name]=""
  else
    status[$name]=FAIL; detail[$name]="HTTP $code"
  fi
  echo "$name ${status[$name]} ${detail[$name]}"
done

# TLS: days until the certificate served for mvv42.ru expires.
end="$(echo | timeout 20 openssl s_client -servername mvv42.ru -connect mvv42.ru:443 2>/dev/null \
  | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"
if [ -n "$end" ] && days=$(( ($(date -d "$end" +%s) - NOW) / 86400 )) && [ "$days" -ge "$CERT_MIN_DAYS" ]; then
  status[cert]=OK; detail[cert]=""
else
  status[cert]=FAIL; detail[cert]="${days:+$days дн. до истечения}"; detail[cert]="${detail[cert]:-сертификат не прочитан}"
fi
echo "cert ${status[cert]} ${detail[cert]} (${days:-?} days)"

# ---- compare with the previous run ----
declare -A prev
last_alert=0
if [ -f "$STATE" ]; then
  while read -r k v; do
    case "$k" in
      _last_alert) last_alert="$v" ;;
      "") ;;
      *) prev[$k]="$v" ;;
    esac
  done < "$STATE"
fi

changed=() failing=()
for k in "${!status[@]}"; do
  [ "${status[$k]}" = FAIL ] && failing+=("$k")
  if [ -n "${prev[$k]:-}" ] && [ "${prev[$k]}" != "${status[$k]}" ]; then changed+=("$k"); fi
  if [ -z "${prev[$k]:-}" ] && [ "${status[$k]}" = FAIL ]; then changed+=("$k"); fi
done

send=false
if [ "${#changed[@]}" -gt 0 ]; then send=true
elif [ "${#failing[@]}" -gt 0 ] && [ $((NOW - last_alert)) -ge "$REMIND_AFTER" ]; then send=true
fi

if $send; then
  msg=""
  if [ "${#failing[@]}" -gt 0 ]; then
    msg="🔴 mvv42.ru снаружи: проблемы"$'\n'
    for k in $(printf '%s\n' "${failing[@]}" | sort); do msg+="• $k: ${detail[$k]}"$'\n'; done
  else
    msg="✅ mvv42.ru снаружи: всё снова доступно"$'\n'
  fi
  for k in $(printf '%s\n' "${changed[@]}" | sort); do
    [ "${status[$k]}" = OK ] && msg+="• $k: восстановлено"$'\n'
  done
  msg+="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
  if [ -n "${TG_TOKEN:-}" ] && [ -n "${TG_CHAT:-}" ]; then
    curl -s -o /dev/null -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
      -d chat_id="$TG_CHAT" --data-urlencode text="$msg" || echo "telegram send failed" >&2
  else
    printf '%s\n' "$msg"
  fi
  last_alert="$NOW"
fi

mkdir -p "$STATE_DIR"
{ for k in "${!status[@]}"; do echo "$k ${status[$k]}"; done; echo "_last_alert $last_alert"; } > "$STATE"

# A failing run marks the workflow red as well (visible in the Actions list).
[ "${#failing[@]}" -eq 0 ]
