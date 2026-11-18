# Nagios Core + SNMPv2c — лабораторія моніторингу

Навчальний проєкт: **config-as-code** система моніторингу мережевого обладнання та IP-камер
через SNMPv2c, з алертами в Telegram і повним аудитом змін у Git.

| Рішення | Вибір | Чому |
|---|---|---|
| Ядро | **Nagios Core 4.x** (безкоштовний) | вимога «безкоштовно», SNMP «з коробки», мінімум рухомого |
| Протокол | **SNMPv2c** | підтримка камер/дешевих комутаторів |
| Джерело правди | **Git** (`inventory/hosts.yml`) | навчальний масштаб; NetBox додається пізніше без зміни схеми |
| Git-хостинг | **GitHub** + GitHub Actions | безкоштовний CI, PR-рев'ю як аудит змін |
| Алерти | **Telegram** (webhook через `curl`) | безкоштовно, мобільно |
| Середовище | **Linux + Docker Compose** | одна команда на будь-якому хості |
| Пристрої | **симулятори SNMP** (Docker) | реальних камер немає — вчимось на емуляторах |

---

## 1. Схема

```
        inventory/hosts.yml        ← SOURCE OF TRUTH (єдине місце правок)
                  │
          tools/gen.py  (генератор)
                  │
        nagios/etc/conf.d/generated/*.cfg   ← генероване, комітиться в Git
                  │
   ┌──────────────▼───────────────┐
   │  Nagios Core (контейнер)     │  check_ping / check_tcp / check_snmp
   │  UI: http://<host>:8080      │
   └──────┬────────────────┬──────┘
   SNMPv2c│161/udp         │ notify_telegram.sh
          │                ▼
  ┌───────▼────────┐   Telegram (NOC-група)
  │ sim-switch     │
  │ sim-camera     │  172.30.0.0/24 (окрема lab-мережа = VLAN моніторингу)
  └────────────────┘
          ▲
   Git push → GitHub Actions (nagios -v + перевірка актуальності генерації)
```

Ключове правило: **конфіг на проді руками не редагують**. Прод — це результат `git pull` +
`tools/deploy.sh`. Будь-яка зміна проходить через PR і `nagios -v` у CI.

---

## 2. Швидкий старт (Ubuntu VM з попередніх сесій)

```bash
# 1. Клонувати репозиторій
git clone https://github.com/n-work1100/test_monitoring.git
cd test_monitoring

# 2. Налаштувати секрети (у Git НЕ потрапляють)
cp .env.example .env
nano .env            # SNMP_COMMUNITY (TG_TOKEN/TG_CHAT_ID — пізніше)

# 3. Підняти стек однією командою:
#    pull -> gen -> resource.cfg -> nagios -v -> up
sudo apt install -y python3-yaml     # потрібен генератору
./tools/deploy.sh

# 4. Перевірити вручну (опційно)
docker compose run --rm --entrypoint nagios nagios -v /opt/nagios/etc/nagios.cfg
curl -sI http://localhost:8080/nagios/ | head -1     # очікуємо 401

# 5. Відкрити UI
#    http://<ip-ubuntu-vm>:8080/nagios/   (логін nagiosadmin / nagios)
```

Очікуваний стан через 3–5 хв: `sw-lab-01` та `cam-lab-01` — **UP**, сервіси PING/SNMP-Uptime —
**OK**, RTSP-554/WEB-80 на камері — **OK** (симулятор відкриває ці порти).

Перевірка Telegram без Nagios:

```bash
docker compose exec nagios /opt/nagios-config/tools/notify_telegram.sh \
  service PROBLEM cam-lab-01 RTSP-554 CRITICAL "test alert" "$(date '+%F %T')"
```

---

## 3. Як додати пристрій (робочий процес)

1. Додати запис у `inventory/hosts.yml`:

```yaml
  - name: sw-kyiv-acc-02
    alias: "Access switch, Kyiv office"
    address: 10.20.1.12
    role: switch          # switch | camera | nvr
    site: kyiv            # довільний, стає hostgroup site-kyiv
```

2. `python tools/gen.py` — оновить `nagios/etc/conf.d/generated/`.
3. `git checkout -b add-sw-kyiv-acc-02` → commit → push → **Pull Request**.
4. CI: `nagios -v` + перевірка, що генеровані файли закомічені.
5. Merge → на хості `./tools/deploy.sh` (або `make deploy`).

Прибрати пристрій з моніторингу, не видаляючи з SoT: `monitoring: false`.

---

## 4. Що моніторимо

### Комутатор (`role: switch`)
| Сервіс | Команда | Сенс |
|---|---|---|
| PING | `check_ping` | доступність (ICMP) |
| SNMP-Uptime | `check_snmp_uptime` | `sysUpTime` < 5 хв → перезавантаження |
| SNMP-IfNumber | `check_snmp_ifnumber` | SNMP відповідає, MIB цілий |

### IP-камера (`role: camera`)
| Сервіс | Команда | Сенс |
|---|---|---|
| PING | `check_ping` | доступність |
| SNMP-Uptime | `check_snmp_uptime` | перезавантаження камери |
| RTSP-554 | `check_tcp!554` | основний стрім живий |
| WEB-80 | `check_tcp!80` | веб-інтерфейс/ONVIF |

### NVR (`role: nvr`)
PING + SNMP-Uptime + RTSP-554.

### Алерти
- `max_check_attempts 3` + `retry_interval 1` → короткі флапи не шумлять;
- `first_notification_delay`/`notification_interval 60` → нагадування раз на годину;
- `hostdependency`: камера/NVR залежить від комутатора свого `site` → коли комутатор лежить,
  Telegram не заспамлюється 20-ма «камера недоступна».

---

## 5. Структура репозиторію

```
nagios-snmp-lab/
├─ inventory/hosts.yml               # SOURCE OF TRUTH
├─ tools/
│  ├─ gen.py                         # inventory -> nagios/etc/conf.d/generated
│  ├─ notify_telegram.sh             # notification command
│  └─ deploy.sh                      # pull + validate + restart (на Linux-хості)
├─ nagios/etc/
│  ├─ nagios.cfg                     # ядро
│  ├─ resource.cfg                   # ГЕНЕРУЄТЬСЯ deploy.sh (у .gitignore)
│  └─ conf.d/
│     ├─ 00-commands.cfg             # check_* + notify-*
│     ├─ 05-templates.cfg            # generic-host, switch-host, camera-host...
│     ├─ 10-contacts.cfg             # контакт/група NOC (Telegram)
│     └─ generated/                  # АВТОГЕНЕРАЦІЯ, комітиться
│        ├─ hosts-<site>.cfg
│        ├─ services-<site>.cfg
│        ├─ groups.cfg
│        └─ dependencies.cfg
├─ sim/
│  ├─ snmpd/                         # симулятор комутатора (net-snmp)
│  └─ camera/                        # симулятор камери (snmpd + RTSP/80)
├─ .github/workflows/ci.yml          # nagios -v + актуальність генерації + gitleaks
├─ docker-compose.yml
├─ Makefile
├─ .env.example
└─ docs/
   ├─ decisions.md                   # ADR: чому саме так (відповіді -51.1)
   └─ runbook.md                     # деплой, відкат, діагностика
```

---

## 6. Безпека SNMPv2c

- community **не в Git**: `.env` + `nagios/etc/resource.cfg` (створює `deploy.sh`, `chmod 600`).
- окрема мережа `172.30.0.0/24` = аналог VLAN моніторингу; на реальному обладнанні —
  ACL «дозволити UDP/161 лише з IP Nagios».
- `public` не використовуємо, community — довгий випадковий рядок.
- CI має `gitleaks` → випадковий коміт із токеном падає на PR.
- SNMPv3 (`authPriv`) — наступний крок, коли з'явиться обладнання з його підтримкою.

---

## 7. Наступні кроки

- [ ] `check_nwc_health` (порти, помилки, CPU, PoE) для комутаторів — див. `docs/runbook.md`.
- [ ] ffprobe-пробник «стрім живий і бітрейт у нормі» (SNMP цього не показує).
- [ ] InfluxDB + Grafana для графіків.
- [ ] Міграція SoT: `inventory/hosts.yml` → NetBox + `generator.py` (схема не змінюється).
- [ ] Розподілені поллери (Mod-Gearman / Naemon) при > 500 об'єктів.
