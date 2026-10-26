FROM alpine:3.24.3@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a

ARG VCS_REF=unknown
LABEL org.opencontainers.image.source="https://github.com/zhdkirill/wireguard" \
      org.opencontainers.image.revision="${VCS_REF}"

RUN apk add --no-cache bash iproute2 iptables socat tini wireguard-tools
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY status.sh /usr/local/bin/wireguard-status
COPY lib/ /usr/local/lib/wireguard/
RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/wireguard-status

ENTRYPOINT ["/sbin/tini", "-g", "--", "/usr/local/bin/entrypoint.sh"]
