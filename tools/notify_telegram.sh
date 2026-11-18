#!/usr/bin/env bash
# ============================================================================
# notify_telegram.sh — notification command для Nagios Core
#
#   host:    notify_telegram.sh host    <notiftype> <host> <state> <output> <datetime>
#   service: notify_telegram.sh service <notiftype> <host> <service> <state> <output> <datetime>
#
# Змінні оточення (з .env через docker compose):
#   TG_TOKEN     — токен бота від @BotFather            (обов'язково)
#   TG_CHAT_ID   — chat_id групи/каналу/юзера           (обов'язково)
#   TG_THREAD_ID — id топіка в групі (опційно)
# ============================================================================
set -uo pipefail

if [ $# -lt 5 ]; then
    echo "usage: $0 host|service <notiftype> <host> [<service>] <state> <output> [<datetime>]" >&2
    exit 2
fi

TYPE="$1"; shift
NOTIF="$1"; shift
HOST="$1"; shift

if [ "$TYPE" = "service" ]; then
    SERVICE="${1:-}"; shift || true
else
    SERVICE=""
fi
STATE="${1:-UNKNOWN}"; shift || true
OUTPUT="${1:-}"; shift || true
WHEN="${1:-$(date '+%F %T')}"; shift || true

: "${TG_TOKEN:?TG_TOKEN не заданий (перевірте .env)}"
: "${TG_CHAT_ID:?TG_CHAT_ID не заданий (перевірте .env)}"

# HTML-escape для parse_mode=HTML
esc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

case "$STATE" in
    OK|UP)        ICON="✅" ;;
    WARNING)      ICON="⚠️" ;;
    CRITICAL|DOWN) ICON="🛑" ;;
    UNREACHABLE)  ICON="🚫" ;;
    *)            ICON="ℹ️" ;;
esac

if [ "$TYPE" = "host" ]; then
    TEXT="$ICON <b>HOST ${STATE}</b>  <code>$(esc "$HOST")</code>
<i>${NOTIF}</i> · ${WHEN}
$(esc "$OUTPUT")"
else
    TEXT="$ICON <b>${STATE}</b>  <code>$(esc "$HOST")</code> / <b>$(esc "$SERVICE")</b>
<i>${NOTIF}</i> · ${WHEN}
$(esc "$OUTPUT")"
fi

ARGS=(
    -sS --max-time 15
    -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage"
    --data-urlencode "chat_id=${TG_CHAT_ID}"
    --data-urlencode "text=${TEXT}"
    -d "parse_mode=HTML"
    -d "disable_web_page_preview=true"
)
[ -n "${TG_THREAD_ID:-}" ] && ARGS+=(-d "message_thread_id=${TG_THREAD_ID}")

if ! curl "${ARGS[@]}"; then
    echo "notify_telegram.sh: не вдалося відправити повідомлення" >&2
    exit 1
fi
echo
