FROM alpine:3.20

RUN apk add --no-cache net-snmp net-snmp-tools socat

COPY snmpd.conf /etc/snmp/snmpd.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 161/udp 554/tcp 80/tcp

ENTRYPOINT ["/entrypoint.sh"]
