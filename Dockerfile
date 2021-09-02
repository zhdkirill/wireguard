FROM alpine:3.14
RUN apk --no-cache --no-progress upgrade && \
    apk --no-cache --no-progress add wireguard-tools iptables
RUN echo $'#!/usr/bin/env ash\n\
set -eo pipefail\n\
wg-quick up wg0\n\
sleep infinity' > /usr/local/bin/docker-entrypoint.sh && \
    chmod +x /usr/local/bin/docker-entrypoint.sh
ENTRYPOINT ["docker-entrypoint.sh"]
