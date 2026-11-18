#!/bin/sh
# Симулятор камери: SNMP-агент + відкриті порти, які перевіряє Nagios
#   TCP/554 — «RTSP» (check_tcp!554)
#   TCP/80  — «веб-інтерфейс» (check_tcp!80)
set -e

socat TCP-LISTEN:554,fork,reuseaddr EXEC:/bin/cat &
socat TCP-LISTEN:80,fork,reuseaddr EXEC:/bin/cat &

exec snmpd -f -Lo -C -c /etc/snmp/snmpd.conf
