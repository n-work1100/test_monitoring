# Runbook

## 1. Перший запуск на Ubuntu VM

```bash
# Docker уже має бути встановлений (на навчальній VM — docker-ce з
# download.docker.com: docker-ce + docker-compose-plugin). Перевірка:
docker --version && docker compose version

# Якщо Docker ще НЕ встановлений — ставимо з офіційного репозиторію Docker:
#   https://docs.docker.com/engine/install/ubuntu/
# НЕ використовуйте docker.io + docker-compose-v2 з репозиторію Ubuntu:
# це інші (старіші) пакети, вони конфліктують із docker-ce.
sudo apt install -y git make python3-yaml

# Група docker: після цього ОБОВ'ЯЗКОВО перелогінитись (нова SSH-сесія).
# `newgrp docker` у неінтерактивному скрипті не зараховується.
sudo usermod -aG docker "$USER"

git clone https://github.com/n-work1100/test_monitoring.git
cd test_monitoring
cp .env.example .env && nano .env      # SNMP_COMMUNITY, NAGIOS_PORT; TG_TOKEN/TG_CHAT_ID — пізніше

bash tools/deploy.sh                   # pull + gen + resource.cfg + nagios -v + up + restart
```

`deploy.sh` сам перевіряє передумови (docker, compose-plugin, `python3-yaml`), рендерить
`nagios/etc/resource.cfg` з `.env` (права `644` — його читають CGI) і **спочатку** виконує
`nagios -v`; при помилці конфігу рестарту не буде.

UI: `http://<ip-vm>:8080/nagios/` — логін `nagiosadmin`, пароль `nagios`
(`nagios/etc/htpasswd.users` створюється автоматично при першому старті контейнера; змінити:
`docker compose exec nagios htpasswd /opt/nagios/etc/htpasswd.users nagiosadmin`).
Порт задається `NAGIOS_PORT` у `.env`; якщо 8080 зайнятий — напр. `8090`.

Перевірка «живий чи ні» без браузера: `curl -sI "http://localhost:${NAGIOS_PORT:-8080}/nagios/" | head -1`
→ очікуємо `HTTP/1.1 401 Unauthorized` (Apache просить логін; `500` = проблема CGI,
`connection refused` = контейнер не піднявся).

## 2. Telegram-бот (5 хвилин)

1. `@BotFather` → `/newbot` → отримати `TG_TOKEN`.
2. Чат: або особистий чат з ботом (натиснути `Start`), або група NOC. У ботів увімкнений
   privacy mode, тому в групі їх треба «розбудити»: надіслати `/start@<ваш_бот>` (або
   вимкнути privacy у BotFather: `/setprivacy` → Disable → пере-додати бота).
3. Отримати `chat_id` (для груп він від'ємний, напр. `-1001234567890`):
   ```bash
   set -a; . ./.env; set +a
   curl -s "https://api.telegram.org/bot$TG_TOKEN/getUpdates" | python3 -c '
   import sys, json
   for r in json.load(sys.stdin).get("result", []):
       m = r.get("message") or r.get("channel_post") or {}
       c = m.get("chat") or {}
       if c: print(c.get("id"), c.get("type"), c.get("title") or c.get("username") or c.get("first_name"))
   '
   ```
   Порожній `result` означає, що бот ще не отримував повідомлень — напишіть йому і повторіть.
4. Записати `TG_TOKEN`/`TG_CHAT_ID` у `.env` і **пересоздати** контейнер (env_file читається
   лише при створенні): `docker compose up -d --force-recreate nagios`
   (історія не втратиться — вона в томі `nagios-var`).
5. Перевірка: `make notify-test`. Якщо тихо — `docker compose exec nagios bash -x /opt/nagios-config/tools/notify_telegram.sh service PROBLEM cam-lab-01 RTSP-554 CRITICAL "test" "$(date '+%F %T')"`
   покаже відповідь Telegram (`chat not found` = невірний `chat_id`).

## 3. Перевірка, що моніторинг справді працює

```bash
# SNMP з контейнера Nagios напряму
docker compose exec nagios /opt/nagios/libexec/check_snmp \
  -H 172.30.0.11 -P 2c -C lab_ro_c0mm -o 1.3.6.1.2.1.1.3.0 -l Uptime

# хто саме відповів (sysName, а не sysDescr — див. розділ 4)
docker compose exec nagios snmpget -v2c -c lab_ro_c0mm -r 1 -t 3 -On \
  172.30.0.11 1.3.6.1.2.1.1.5.0 2>/dev/null

# порти камери
docker compose exec nagios /opt/nagios/libexec/check_tcp -H 172.30.0.21 -p 554

# примусовий алерт: погасити симулятор і дочекатися DOWN (≈2-3 хв)
docker compose stop sim-camera
# лог Nagios — це файл, не stdout контейнера:
docker compose exec nagios tail -f /opt/nagios/var/nagios.log | grep --line-buffered 'cam-lab-01'
docker compose start sim-camera
```

Очікування: у Telegram прийде `🛑 HOST DOWN cam-lab-01` (а не чотири сервісні — див. нижче),
після старту — `✅ HOST UP … RECOVERY`.

Якщо хоста немає (DOWN), сервісні нотифікації **не** надсилаються: ядро примусово
переводить сервіси в HARD і шле лише один `HOST NOTIFICATION` — це штатна поведінка
(`notifications.c`), а не зламаний контакт. Тому в лозі під час такого тесту видно
`SERVICE ALERT`, але не `SERVICE NOTIFICATION`; перевіряти треба `HOST NOTIFICATION`.

## 4. Типові проблеми

| Симптом | Причина | Рішення |
|---|---|---|
| `check_snmp: Timeout` | неправильний community або SNMP не дозволений з 172.30.0.0/24 | звірити `.env` ↔ `sim/*/snmpd.conf`; `docker compose exec nagios snmpget -v2c -c ...` |
| `nagios -v`: `Error: Could not find any host matching ...` | у `generated/` лишилися старі файли після перейменування сайту | `rm -rf nagios/etc/conf.d/generated/* && python tools/gen.py` |
| `resource.cfg` порожній / `$USER5$` невідомий | не виконано `deploy.sh` (він рендерить файл) | `./tools/deploy.sh` або `make validate` |
| `nagios -v`: `Error: ... period '24x7' ... is not defined anywhere!` | немає `01-timeperiods.cfg` або він не підключений у `nagios.cfg` | перевірити `cfg_file=.../01-timeperiods.cfg` і `define timeperiod { timeperiod_name 24x7 ... }` |
| Telegram мовчить | бот не в групі / `chat_id` неправильний / нотифікації не дозволені | перевірити `curl .../sendMessage` вручну; у `10-contacts.cfg` `*_notifications_enabled 1` |
| алерти приходять пачкою при падінні комутатора | немає `hostdependency` | перевірити `generated/dependencies.cfg` (генерується за `site`) |
| `snmpget` пише `Cannot find module (...MIB)`, `Bad operator (INTEGER)` | в образі неповний набір MIB (net-snmp у `jasonrivers/nagios`) | на діагностику не впливає: працюйте числовими OID (`-On`) і ховайте шум `2>/dev/null` |
| `sysDescr` показує `Linux <container-id>` замість `sim-switch` | у симуляторі sysDescr береться з ядра контейнера, однаковий для обох | ідентичність пристрою — `sysName` (`1.3.6.1.2.1.1.5.0`), заданий у `sim/*/snmpd.conf` |
| у лозі є `SERVICE ALERT ... CRITICAL;HARD;1`, але немає `SERVICE NOTIFICATION` | хост уже в HARD-DOWN: ядро примусово переводить сервіси в HARD і **не** шле по них нотифікації (`notifications.c`: "if the host is down or unreachable…") | це задум Nagios, не помилка; при падінні хоста приходить один `HOST NOTIFICATION`, а не N сервісних |
| після рестарту пристрою `SNMP-Uptime` не дає WARNING | пороги вказані в секундах, а `check_snmp` для Timeticks порівнює **тіки** (1/100 c) | пороги в тіках: `-w 30000:` (5 хв), `-c 0:` (CRITICAL вимкнено: рестарт = WARNING, а не аварія) |

## 5. Додати `check_nwc_health` (порти, помилки, CPU, PoE)

```bash
# Образ jasonrivers/nagios — Debian (apt), НЕ Alpine: apk тут не існує.
docker compose exec nagios sh -c '
  apt-get update && apt-get install -y --no-install-recommends curl perl &&
  curl -fsSL -o /opt/nagios/libexec/check_nwc_health \
    https://raw.githubusercontent.com/lausser/check_nwc_health/master/check_nwc_health &&
  chmod +x /opt/nagios/libexec/check_nwc_health'
```
Далі розкоментувати `check_nwc_interfaces` у `00-commands.cfg` і додати сервіс у
`ROLE_SERVICES["switch"]` у `tools/gen.py`. **Краще** — вбудувати це в власний Dockerfile
поверх `jasonrivers/nagios`, щоб не робити ручних кроків на проді.

## 6. Відкат

```bash
cd ~/test_monitoring
git log --oneline -n 10
git revert <sha>          # або: git checkout <tag> -- nagios/etc
bash tools/deploy.sh
```

`deploy.sh` спочатку робить `nagios -v`; якщо конфіг зламаний — рестарту не буде,
прод продовжує працювати на попередній валідній версії.

Історія та статуси Nagios лежать у іменованому томі `nagios-var`, тому переживають
`up --force-recreate` (напр. після зміни `.env`) і `docker compose down`.
Видаляються лише `make clean` (`down -v`).

## 7. Приймання (чек-лист)

Перевірено на живій інсталяції 2026-11-18: Ubuntu 26.04.1, Docker 29.1.3, Compose v2.40.3,
Nagios 4.5.12, 2 хости / 7 сервісів.

> **Історичний результат.** Цифри вище отримані на попередній VM. На новій VM
> (2026-11-24, Docker 29.10.0, Compose 5.8.0) чек-лист перевіряється заново;
> до повторного підтвердження це не гарантія працездатності.

**Стан: 13 з 13 підтверджено 19.11.2026 (стара VM).** Два останні пункти:
- п.2 — `curl -sI localhost:8080/nagios/ | head -1` → `HTTP/1.1 401 Unauthorized`;
- п.11 — `docker compose restart sim-camera` → `SNMP-Uptime;WARNING` (uptime 2:22),
  далі `OK` (5:22), **без** `CRITICAL`.

| # | Перевірка | Команда | Очікування |
|---|---|---|---|
| 1 | Стек піднято | `docker compose ps` | 3× `Up`: nagios, sim-switch, sim-camera |
| 2 | UI живий | `curl -sI localhost:8080/nagios/ \| head -1` | `HTTP/1.1 401 Unauthorized` |
| 3 | ICMP | `docker compose exec nagios /opt/nagios/libexec/check_ping -H 172.30.0.11 -w 200,20% -c 500,60%` | `PING OK - Packet loss = 0%` |
| 4 | SNMPv2c | `… check_snmp -H 172.30.0.11 -P 2c -C $COMM -o 1.3.6.1.2.1.1.3.0 -l Uptime -u ""` | `SNMP OK - Uptime Timeticks: …` |
| 5 | Ідентичність | `… snmpget -v2c -c $COMM -On 172.30.0.11 1.3.6.1.2.1.1.5.0 2>/dev/null` | `STRING: "sim-switch"` |
| 6 | Порти камери | `… check_tcp -H 172.30.0.21 -p 554` / `-p 80` | `TCP OK - 0.00x second response time` |
| 7 | Негатив SNMP | `… check_snmp -H 172.30.0.11 -P 2c -C wrong_community -o 1.3.6.1.2.1.1.3.0 -t 5` | `CRITICAL - Plugin timed out` |
| 8 | Негатив ICMP | `… check_ping -H 172.30.0.99 -w 200,20% -c 500,60%` | `CRITICAL - Host Unreachable` |
| 9 | Реальна аварія | `docker compose stop sim-camera` (≈2-3 хв) | `HOST ALERT … DOWN;HARD;3` + `HOST NOTIFICATION` + 🛑 у Telegram |
| 10 | Відновлення | `docker compose start sim-camera` (≈2-3 хв) | `HOST ALERT … UP` + `RECOVERY` + ✅ у Telegram |
| 11 | Перезавантаження = WARNING | `docker compose restart sim-camera` | `SNMP-Uptime;WARNING` (0-5 хв), далі `OK`; **без** CRITICAL |
| 12 | Telegram | `make notify-test` | 🛑 `CRITICAL cam-lab-01 / RTSP-554` |
| 13 | TZ | `docker compose exec nagios date` | `EET`/`EEST`, не `UTC` |

Єдине джерело істини — `nagios.log` (не `docker compose logs`: Nagios пише у файл):

```bash
docker compose exec nagios tail -n 300 /opt/nagios/var/nagios.log \
  | grep -E 'cam-lab-01|NOTIFICATION' | tail -25
```

Очікувана послідовність під час падіння: `…;CRITICAL;SOFT;1` → `…;CRITICAL;HARD;3` →
`HOST ALERT …;DOWN;HARD;3` → `HOST NOTIFICATION …;DOWN;…`, після старту — `UP` + `RECOVERY`.
