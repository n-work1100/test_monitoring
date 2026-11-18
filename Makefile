# Лабораторія Nagios + SNMPv2c. Усі «небезпечні» цілі — лише через deploy.
SHELL := /bin/bash
PYTHON ?= python
COMPOSE ?= docker compose

.PHONY: help gen check validate up down restart logs ps deploy notify-test clean

help:
	@echo "make gen          - згенерувати конфіг Nagios з inventory/hosts.yml"
	@echo "make check        - перевірити, що generated/ актуальний (як у CI)"
	@echo "make validate     - nagios -v (потрібен Docker)"
	@echo "make up|down|logs - керування стеком"
	@echo "make notify-test  - тестовий алерт у Telegram"
	@echo "make deploy       - pull + gen + validate + restart (на Linux-хості)"

gen:
	$(PYTHON) tools/gen.py

check: gen
	@git diff --exit-code -- nagios/etc/conf.d/generated \
		|| { echo "ERROR: generated/ відстає від inventory/hosts.yml — закомітьте результат tools/gen.py"; exit 1; }

validate:
	@test -f nagios/etc/resource.cfg || printf '$$USER1$$=/opt/nagios/libexec\n$$USER5$$=dummy\n' > nagios/etc/resource.cfg
	$(COMPOSE) run --rm --entrypoint nagios nagios -v /opt/nagios/etc/nagios.cfg

up:
	$(COMPOSE) up -d --build

down:
	$(COMPOSE) down

restart:
	$(COMPOSE) restart nagios

logs:
	$(COMPOSE) logs -f --tail=100 nagios

ps:
	$(COMPOSE) ps

deploy:
	bash ./tools/deploy.sh

notify-test:
	$(COMPOSE) exec nagios bash /opt/nagios-config/tools/notify_telegram.sh \
		service PROBLEM cam-lab-01 RTSP-554 CRITICAL "make notify-test" "$$(date '+%F %T')"

clean:
	$(COMPOSE) down -v --remove-orphans
