# Клиент NaiveProxy как обычный контейнер: naive работает главным процессом.
# systemd не нужен, привилегии не нужны.
FROM debian:12-slim

# TARGETARCH подставляет buildkit: amd64, arm64, arm
ARG TARGETARCH

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl ca-certificates xz-utils; \
    case "${TARGETARCH}" in \
      amd64) arch=x64 ;; \
      arm64) arch=arm64 ;; \
      arm)   arch=arm ;; \
      *) echo "неподдерживаемая архитектура: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    release="$(curl -fsSL https://api.github.com/repos/klzgrad/naiveproxy/releases/latest)"; \
    tag="$(printf '%s\n' "$release" | grep -m1 '"tag_name"' | cut -d'"' -f4)"; \
    test -n "$tag"; \
    curl -fsSL -o /tmp/naive.tar.xz \
      "https://github.com/klzgrad/naiveproxy/releases/download/${tag}/naiveproxy-${tag}-linux-${arch}.tar.xz"; \
    tar -xJf /tmp/naive.tar.xz -C /tmp; \
    install -m 0755 "$(find /tmp -name naive -type f -print -quit)" /usr/local/bin/naive; \
    /usr/local/bin/naive --version; \
    rm -rf /tmp/* /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# внутри контейнера слушаем 0.0.0.0, иначе соседние контейнеры не достучатся
ENV SOCKS_PORT=1080 HTTP_PORT=8080
EXPOSE 1080 8080

HEALTHCHECK --interval=60s --timeout=15s --start-period=10s --retries=3 \
  CMD curl -fsS --max-time 10 --socks5-hostname "127.0.0.1:${SOCKS_PORT}" https://api.ipify.org >/dev/null || exit 1

ENTRYPOINT ["/entrypoint.sh"]
