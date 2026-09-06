#!/bin/sh
# Собирает конфиг naive из переменных окружения и запускает клиент.
#
#   NAIVE_LINK=naive+https://ЛОГИН:ПАРОЛЬ@домен:443
# либо по частям:
#   NAIVE_DOMAIN / NAIVE_USER / NAIVE_PASSWORD / NAIVE_PORT

set -eu

SOCKS_PORT="${SOCKS_PORT:-1080}"
HTTP_PORT="${HTTP_PORT:-8080}"

if [ -n "${NAIVE_LINK:-}" ]; then
  raw="${NAIVE_LINK#naive+}"
  raw="${raw#*://}"
  creds="${raw%%@*}"
  hostport="${raw##*@}"
  NAIVE_USER="${creds%%:*}"
  NAIVE_PASSWORD="${creds#*:}"
  case "$hostport" in
    *:*) NAIVE_DOMAIN="${hostport%%:*}"; NAIVE_PORT="${hostport##*:}" ;;
    *)   NAIVE_DOMAIN="$hostport"; NAIVE_PORT=443 ;;
  esac
  NAIVE_DOMAIN="${NAIVE_DOMAIN%/}"
  NAIVE_PORT="${NAIVE_PORT%/}"
fi

: "${NAIVE_DOMAIN:?нужен NAIVE_LINK или NAIVE_DOMAIN}"
: "${NAIVE_USER:?нужен NAIVE_USER}"
: "${NAIVE_PASSWORD:?нужен NAIVE_PASSWORD}"
NAIVE_PORT="${NAIVE_PORT:-443}"

cat > /tmp/config.json <<EOF
{
  "listen": [
    "socks://0.0.0.0:${SOCKS_PORT}",
    "http://0.0.0.0:${HTTP_PORT}"
  ],
  "proxy": "https://${NAIVE_USER}:${NAIVE_PASSWORD}@${NAIVE_DOMAIN}:${NAIVE_PORT}"
}
EOF

echo "[naive] прокси: ${NAIVE_USER}@${NAIVE_DOMAIN}:${NAIVE_PORT}"
echo "[naive] входы: socks5 :${SOCKS_PORT}, http :${HTTP_PORT}"

exec /usr/local/bin/naive /tmp/config.json
