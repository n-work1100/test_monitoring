#!/usr/bin/env bash
# ============================================================================
# deploy.sh — оновлення моніторингу на Linux-хості (Ubuntu VM)
#
#   git pull -> regenerate -> render resource.cfg -> nagios -v -> restart
#
# Безпека: спочатку валідація конфігу; якщо nagios -v падає — нічого не
# перезапускається (прод залишається на попередній валідній версії).
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

COMPOSE="docker compose"
[ -f .env ] || { echo "Немає .env — скопіюйте .env.example у .env і заповніть"; exit 1; }

# --- передумови -------------------------------------------------------------
command -v python3 >/dev/null 2>&1 || { echo "Потрібен python3"; exit 1; }
python3 -c 'import yaml' 2>/dev/null || {
    echo "Немає PyYAML. Встановіть:  sudo apt install -y python3-yaml"
    exit 1
}
command -v docker >/dev/null 2>&1 || { echo "Немає docker (див. docs/runbook.md, етап 3)"; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "Немає docker compose plugin (docker-compose-v2)"; exit 1; }

# shellcheck disable=SC1091
set -a; . ./.env; set +a
: "${SNMP_COMMUNITY:?SNMP_COMMUNITY не заданий у .env}"

echo "==> git pull"
git pull --ff-only

echo "==> regenerate from inventory/hosts.yml"
python3 tools/gen.py

echo "==> render nagios/etc/resource.cfg (не в Git)"
cat > nagios/etc/resource.cfg <<EOF
\$USER1\$=/opt/nagios/libexec
\$USER5\$=${SNMP_COMMUNITY}
EOF
# 644, а не 600: CGI читають цей файл під користувачем nagios (Apache),
# інакше веб-інтерфейс падає з "Could not open resource file".
chmod 644 nagios/etc/resource.cfg

echo "==> nagios -v (перевірка об'єктів)"
$COMPOSE run --rm --entrypoint nagios nagios -v /opt/nagios/etc/nagios.cfg

echo "==> (re)start stack"
# Без --build: compose збирає образ лише тоді, коли його немає. Примусова
# перезбірка на кожному деплої пересоздавала sim-* контейнери -> snmpd
# стартував з нуля -> фейкові "перезавантаження" (uptime WARNING) і зайві
# нотифікації. Явна перезбірка: make build.
$COMPOSE up -d

# nagios/etc змонтований з хоста: `up -d` не перезапускає вже працюючий
# контейнер, тому зміни в конфігу не застосуються без явного restart.
# restart зберігає контейнер і /opt/nagios/var (retention), downtime ~2-3 c.
echo "==> restart nagios (перечитати конфіг)"
$COMPOSE restart nagios

echo "==> стан"
$COMPOSE ps
echo "OK. UI: http://<host>:8080/nagios/"
