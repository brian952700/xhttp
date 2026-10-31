ARG DEBIAN_VERSION=13
FROM debian:${DEBIAN_VERSION}
ENV container=docker
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    systemd systemd-sysv dbus ca-certificates curl openssl python3 python3-pexpect \
    shellcheck sudo procps && rm -rf /var/lib/apt/lists/*
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
