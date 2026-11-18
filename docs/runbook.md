# Runbook

## 1. Перший запуск на Ubuntu VM

```bash
sudo apt update
sudo apt install -y docker.io docker-compose-v2 git python3-yaml
sudo usermod -aG docker "$USER" && newgrp docker

git clone https://github.com/n-work1100/test_monitoring.git
cd test_monitoring
cp .env.example .env && nano .env      # SNMP_COMMUNITY; TG_TOKEN/TG_CHAT_ID — пізніше

./tools/deploy.sh                      # pull + gen + resource.cfg + nagios -v + up
```

`deploy.sh` сам перевіряє передумови (docker, compose-plugin, `python3-yaml`), рендерить
`nagios/etc/resource.cfg` з `.env` (права `644` — його читають CGI) і **спочатку** виконує
`nagios -v`; при помилці конфігу рестарту не буде.

UI: `http://<ip-vm>:8080/nagios/` — логін `nagiosadmin`, пароль `nagios`
(`nagios/etc/htpasswd.users` створюється автоматично при першому старті контейнера; змінити:
`docker compose exec nagios htpasswd /opt/nagios/etc/htpasswd.users nagiosadmin`).

Перевірка «живий чи ні» без браузера: `curl -sI http://localhost:8080/nagios/ | head -1`
→ очікуємо `HTTP/1.1 401 Unauthorized` (Apache просить логін; `500` = проблема CGI,
`connection refused` = контейнер не піднявся).

## 2. Telegram-бот (5 хвилин)

1. `@BotFather` → `/newbot` → отримати `TG_TOKEN`.
2. Додати бота в групу NOC.
3. Написати в групу будь-яке повідомлення, потім:
   ```bash
   curl -s "https://api.telegram.org/bot$TG_TOKEN/getUpdates" | grep -E '"id"|"chat"'
   ```
   Для груп `chat.id` від'ємний (напр. `-1001234567890`). Записати в `.env` → `TG_CHAT_ID`.
4. Перевірка: `make notify-test`.

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

# примусовий алерт: погасити симулятор і дочекатися CRITICAL (≈3 хв)
docker compose stop sim-camera
docker compose logs -f nagios | grep -i "cam-lab-01"
docker compose start sim-camera
```

Очікування: у Telegram прийде `🛑 CRITICAL cam-lab-01 / PING`, після старту — `✅ OK`.

## 4. Типові проблеми

| Симптом | Причина | Рішення |
|---|---|---|
| `check_snmp: Timeout` | неправильний community або SNMP не дозволений з 172.30.0.0/24 | звірити `.env` ↔ `sim/*/snmpd.conf`; `docker compose exec nagios snmpget -v2c -c ...` |
| `nagios -v`: `Error: Could not find any host matching ...` | у `generated/` лишилися старі файли після перейменування сайту | `rm -rf nagios/etc/conf.d/generated/* && python tools/gen.py` |
| `resource.cfg` порожній / `$USER5$` невідомий | не виконано `deploy.sh` (він рендерить файл) | `./tools/deploy.sh` або `make validate` |
| Telegram мовчить | бот не в групі / `chat_id` неправильний / нотифікації не дозволені | перевірити `curl .../sendMessage` вручну; у `10-contacts.cfg` `*_notifications_enabled 1` |
| алерти приходять пачкою при падінні комутатора | немає `hostdependency` | перевірити `generated/dependencies.cfg` (генерується за `site`) |
| `snmpget` пише `Cannot find module (...MIB)`, `Bad operator (INTEGER)` | в образі неповний набір MIB (net-snmp у `jasonrivers/nagios`) | на діагностику не впливає: працюйте числовими OID (`-On`) і ховайте шум `2>/dev/null` |
| `sysDescr` показує `Linux <container-id>` замість `sim-switch` | у симуляторі sysDescr береться з ядра контейнера, однаковий для обох | ідентичність пристрою — `sysName` (`1.3.6.1.2.1.1.5.0`), заданий у `sim/*/snmpd.conf` |

## 5. Додати `check_nwc_health` (порти, помилки, CPU, PoE)

```bash
docker compose exec nagios sh -c '
  apk add --no-cache curl perl &&
  curl -fsSL -o /opt/nagios/libexec/check_nwc_health \
    https://raw.githubusercontent.com/lausser/check_nwc_health/master/check_nwc_health &&
  chmod +x /opt/nagios/libexec/check_nwc_health'
```
Далі розкоментувати `check_nwc_interfaces` у `00-commands.cfg` і додати сервіс у
`ROLE_SERVICES["switch"]` у `tools/gen.py`. **Краще** — вбудувати це в власний Dockerfile
поверх `jasonrivers/nagios`, щоб не робити ручних кроків на проді.

## 6. Відкат

```bash
cd ~/nagios-snmp-lab
git log --oneline -n 10
git revert <sha>          # або: git checkout <tag> -- nagios/etc
./tools/deploy.sh
```

`deploy.sh` спочатку робить `nagios -v`; якщо конфіг зламаний — рестарту не буде,
прод продовжує працювати на попередній валідній версії.
