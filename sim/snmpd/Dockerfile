FROM alpine:3.20

RUN apk add --no-cache net-snmp net-snmp-tools

COPY snmpd.conf /etc/snmp/snmpd.conf

EXPOSE 161/udp

# -f  foreground, -Lo log to stdout, -C не читати додаткові конфіги
CMD ["snmpd", "-f", "-Lo", "-C", "-c", "/etc/snmp/snmpd.conf"]
