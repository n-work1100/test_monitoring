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
#
# Безпека:
#   * TG_TOKEN і TG_CHAT_ID передаються curl через stdin (-K -), тому їх
#     немає в аргументах процесу (ps aux, /proc/<pid>/cmdline).
#   * тіло відповіді Telegram не друкується (-o /dev/null): у логи потрапляє
#     лише загальний текст помилки curl без деталей запиту.
#   * помилки HTTP (4xx/5xx) обробляються через curl -f -> exit 1, щоб
#     Nagios бачив невдалу нотифікацію, а не "тихий" успіх.
#   * --retry навмисно НЕ використовується: повторний POST може продублювати
#     повідомлення в чаті.
# ============================================================================
set -uo pipefail

# Ліміт Telegram — 4096 символів на повідомлення. Беремо запас:
# спочатку обрізаємо сирий OUTPUT, потім — готовий TEXT. Усі HTML-теги
# стоять на початку TEXT, тому обрізання хвоста не ламає розмітку.
MAX_OUTPUT_BYTES=2500
MAX_TEXT_BYTES=3900

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

# Валідатор/санітайзер UTF-8 на чистому bash (без зовнішніх утиліт).
# Друкує рядок без некоректних байтів; код повернення: 0 — рядок був коректний,
# 1 — щось відкинуто. Працює побайтово (LC_ALL=C), тому не залежить від локалі.
# Гарантія: після цієї функції рядок завжди є коректним UTF-8.
utf8_clean() {
    local s="$1" LC_ALL=C
    local len=${#s} i=0 k need b b2 out='' bad=0 ok
    while (( i < len )); do
        printf -v b '%d' "'${s:i:1}"
        if (( b < 128 )); then                      # ASCII
            out+="${s:i:1}"
            i=$(( i + 1 ))
            continue
        fi
        if   (( b >= 240 && b <= 244 )); then need=4
        elif (( b >= 224 && b <= 239 )); then need=3
        elif (( b >= 194 && b <= 223 )); then need=2   # 0xC0/0xC1 — overlong
        else need=0; fi                             # 0x80-0xC1, 0xF5-0xFF — не стартові
        if (( need == 0 )); then
            bad=1; i=$(( i + 1 )); continue
        fi
        if (( i + need > len )); then               # обірваний хвіст
            bad=1; break
        fi
        ok=1
        for (( k = 1; k < need; k++ )); do
            printf -v b2 '%d' "'${s:i+k:1}"
            if (( (b2 & 192) != 128 )); then ok=0; break; fi
            if (( k == 1 )); then                   # перевірки другого байта
                if   (( b == 224 && b2 < 160 )); then ok=0   # overlong
                elif (( b == 237 && b2 > 159 )); then ok=0   # surrogate
                elif (( b == 240 && b2 < 144 )); then ok=0   # overlong
                elif (( b == 244 && b2 > 143 )); then ok=0   # > U+10FFFF
                fi
                (( ok )) || break
            fi
        done
        if (( ok )); then
            out+="${s:i:need}"
            i=$(( i + need ))
        else
            bad=1; i=$(( i + 1 ))
        fi
    done
    printf '%s' "$out"
    return "$bad"
}

# Обрізання за байтами з гарантією коректного UTF-8:
#   * iconv -c (Debian) відкидає обірваний хвіст — швидкий шлях;
#   * якщо iconv відсутній або не спрацював — utf8_clean на чистому bash.
# Некоректний UTF-8 не відправляється ніколи.
trunc() {
    local s="$1" max="$2" suffix="${3:-}" out
    if [ "$(printf '%s' "$s" | wc -c)" -le "$max" ]; then
        printf '%s' "$s"
        return 0
    fi
    # pipefail + SIGPIPE від `head` дають ненулевий статус пайплайна, але вивід
    # при цьому коректний, тому статус ігноруємо (|| true).
    out=$(printf '%s' "$s" | head -c "$max") || true
    out=$(utf8_sanitize "$out")
    printf '%s%s' "${out:-}" "$suffix"
}

# Санитайзер UTF-8: пріоритет iconv (швидко, перевірено, завжди є в контейнері),
# інакше — чистий bash utf8_clean. Завжди друкує коректний UTF-8.
utf8_sanitize() {
    local s="$1" out
    if command -v iconv >/dev/null 2>&1; then
        if out=$(printf '%s' "$s" | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null); then
            printf '%s' "$out"
            return 0
        fi
    fi
    utf8_clean "$s" || true
}

# Прибирає незавершений хвіст HTML: обірваний тег («<b …») або сутність
# («&amp» без «;»). Викликається після будь-якого обрізання/санітизації.
html_fix_tail() {
    local out="$1"
    local re_tag='^(.*)<[^>]*$' re_ent='^(.*)&[A-Za-z#0-9]{0,8}$'
    # незакритий тег: останній '<' без '>' після нього
    while [[ "$out" =~ $re_tag ]]; do out="${BASH_REMATCH[1]}"; done
    # незавершена сутність: '&' + до 8 символів без ';'
    while [[ "$out" =~ $re_ent ]]; do out="${BASH_REMATCH[1]}"; done
    printf '%s' "$out"
}

# Обрізає готовий HTML так, щоб не розірвати тег або сутність (&amp; &lt; &gt;).
# Спочатку ріжемо без суфікса, чистимо хвіст, і лише потім додаємо « …».
trunc_html() {
    local s="$1" max="$2" suffix="${3:-}" out
    if [ "$(printf '%s' "$s" | wc -c)" -le "$max" ]; then
        printf '%s' "$s"
        return 0
    fi
    out=$(trunc "$s" "$max" '')
    out=$(html_fix_tail "$out")
    printf '%s%s' "$out" "$suffix"
}

OUTPUT=$(trunc "$OUTPUT" "$MAX_OUTPUT_BYTES" ' …')

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

TEXT=$(trunc_html "$TEXT" "$MAX_TEXT_BYTES" ' …')

# Фінальна гарантія: у Telegram не потрапляє жоден некоректний байт.
# OUTPUT приходить від плагінів і теоретично може бути не-UTF-8, тому це
# виправляється з попередженням у stderr, а не мовчки ламає повідомлення.
clean_text=$(utf8_sanitize "$TEXT")
if [ "$clean_text" != "$TEXT" ]; then
    TEXT="$clean_text"
    echo "notify_telegram.sh: попередження: у тексті виправлено некоректний UTF-8" >&2
fi
# Після вичищення байтів хвіст теоретично може знову стати незавершеним.
TEXT=$(html_fix_tail "$TEXT")

# Конфіг curl через stdin (-K -): токен і chat_id не потрапляють в argv.
CONF=$(printf 'url = "%s"\ndata-urlencode = "chat_id=%s"\n' \
    "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" "${TG_CHAT_ID}")

ARGS=(
    -fsS --max-time 15
    -o /dev/null
    -K -
    -d "parse_mode=HTML"
    -d "disable_web_page_preview=true"
    --data-urlencode "text=${TEXT}"
)
[ -n "${TG_THREAD_ID:-}" ] && ARGS+=(-d "message_thread_id=${TG_THREAD_ID}")

if ! printf '%s' "$CONF" | curl "${ARGS[@]}"; then
    echo "notify_telegram.sh: не вдалося відправити повідомлення" >&2
    exit 1
fi
