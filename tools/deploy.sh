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
chmod 600 nagios/etc/resource.cfg

echo "==> nagios -v (перевірка об'єктів)"
$COMPOSE run --rm --entrypoint nagios nagios -v /opt/nagios/etc/nagios.cfg

echo "==> (re)start stack"
$COMPOSE up -d --build

echo "==> стан"
$COMPOSE ps
echo "OK. UI: http://<host>:8080/nagios/"
