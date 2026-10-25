ARG BASE_IMAGE=wireguard:test
FROM ${BASE_IMAGE}
RUN apk add --no-cache openssh-client openssh-server && passwd -d root
