FROM alpine:3.24.3

LABEL org.opencontainers.image.source="https://github.com/zhdkirill/wireguard"

RUN apk add --no-cache bash iproute2 iptables socat tini wireguard-tools
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY status.sh /usr/local/bin/wireguard-status
RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/wireguard-status

ENTRYPOINT ["/sbin/tini", "-g", "--", "/usr/local/bin/entrypoint.sh"]
