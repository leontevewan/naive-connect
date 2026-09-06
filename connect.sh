#!/usr/bin/env bash
#
# naive-connect — подключение машины к существующему NaiveProxy.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/leontevewan/naive-connect/main/connect.sh)
#
# После подключения в системе появляется команда `naive-connect`:
#   naive-connect switch   — сменить прокси
#   naive-connect status   — куда смотрит сейчас
#   naive-connect test     — проверить туннель

set -Eeuo pipefail
trap 'die "сбой на строке $LINENO — смотрите вывод выше"' ERR

# --- настройки ----------------------------------------------------------------

SELF_URL="https://raw.githubusercontent.com/leontevewan/naive-connect/main/connect.sh"
MANAGER="/usr/local/sbin/naive-connect"
BIN="/usr/local/bin/naive"
CONF_DIR="/etc/naive"
CONFIG="${CONF_DIR}/config.json"
ENV_FILE="${CONF_DIR}/naive-connect.env"
SERVICE="naive-client"

SOCKS_PORT="${SOCKS_PORT:-}"
HTTP_PORT="${HTTP_PORT:-}"
LINK="${LINK:-}"
DOMAIN="${DOMAIN:-}"
USERNAME="${USERNAME:-}"
PASSWORD="${PASSWORD:-}"
PORT="${PORT:-}"
SET_ENV="${SET_ENV:-}"

# --- вывод --------------------------------------------------------------------

if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; DIM=$'\033[2m'; OFF=$'\033[0m'
else
  BOLD=""; RED=""; GREEN=""; YELLOW=""; DIM=""; OFF=""
fi

info() { printf '%s[+]%s %s\n' "$GREEN" "$OFF" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YELLOW" "$OFF" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$RED" "$OFF" "$*" >&2; exit 1; }
step() { printf '\n%s%s%s\n' "$BOLD" "$*" "$OFF"; }

usage() {
  cat <<'EOF'
naive-connect — подключение сервера к вашему NaiveProxy

Команды:
  naive-connect                 подключиться (или переподключиться)
  naive-connect switch [ссылка] сменить прокси и перезапустить службу
  naive-connect status          показать текущий прокси и состояние службы
  naive-connect test            проверить, идёт ли трафик через прокси
  naive-connect uninstall       удалить клиент, службу и конфиг

Реквизиты:
  --link 'naive+https://ЛОГИН:ПАРОЛЬ@домен:443'   ссылка целиком
  --domain, --user, --password, --port            по частям

Прочее:
  --socks-port N   локальный SOCKS5, по умолчанию 1080
  --http-port N    локальный HTTP, по умолчанию 8080
  --env / --no-env прописывать ли http_proxy в /etc/environment
  -h, --help       эта справка

Без аргументов всё спрашивается интерактивно.
EOF
}

# --- команда ------------------------------------------------------------------

CMD="install"
case "${1:-}" in
  switch|status|test|uninstall) CMD="$1"; shift ;;
  install)                      CMD="install"; shift ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    --link)       LINK="${2:-}"; shift 2 ;;
    --domain)     DOMAIN="${2:-}"; shift 2 ;;
    --user)       USERNAME="${2:-}"; shift 2 ;;
    --password)   PASSWORD="${2:-}"; shift 2 ;;
    --port)       PORT="${2:-}"; shift 2 ;;
    --socks-port) SOCKS_PORT="${2:-}"; shift 2 ;;
    --http-port)  HTTP_PORT="${2:-}"; shift 2 ;;
    --env)        SET_ENV=1; shift ;;
    --no-env)     SET_ENV=0; shift ;;
    --uninstall)  CMD="uninstall"; shift ;;
    -h|--help)    usage; exit 0 ;;
    naive+*|http*://*) LINK="$1"; shift ;;   # ссылка позиционным аргументом
    *)            die "неизвестный аргумент: $1 (см. --help)" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "нужны права root: запустите через sudo"

# --- общее --------------------------------------------------------------------

# Ссылка вида naive+https://user:pass@host:port — ровно то, что выдаёт серверный скрипт
parse_link() {
  local raw="${1#naive+}"
  [[ "$raw" =~ ^https?://([^:/@]+):([^@/]+)@([^:/]+)(:([0-9]+))?/?$ ]] || return 1
  USERNAME="${BASH_REMATCH[1]}"
  PASSWORD="${BASH_REMATCH[2]}"
  DOMAIN="${BASH_REMATCH[3]}"
  PORT="${BASH_REMATCH[5]:-443}"
}

load_env() {
  [[ -r "$ENV_FILE" ]] || die "клиент не подключён — запустите подключение сначала"
  # shellcheck disable=SC1090
  . "$ENV_FILE"
}

save_env() {
  umask 077
  cat > "$ENV_FILE" <<EOF
DOMAIN='${DOMAIN}'
USERNAME='${USERNAME}'
PASSWORD='${PASSWORD}'
PORT='${PORT}'
SOCKS_PORT='${SOCKS_PORT}'
HTTP_PORT='${HTTP_PORT}'
EOF
  chmod 600 "$ENV_FILE"
}

write_config() {
  umask 077
  # listen принимает массив: поднимаем SOCKS5 и HTTP сразу.
  # HTTP нужен, чтобы http_proxy подхватывали apt, python-requests и прочие,
  # которые не умеют socks5 из переменной окружения.
  cat > "$CONFIG" <<EOF
{
  "listen": [
    "socks://127.0.0.1:${SOCKS_PORT}",
    "http://127.0.0.1:${HTTP_PORT}"
  ],
  "proxy": "https://${USERNAME}:${PASSWORD}@${DOMAIN}:${PORT}"
}
EOF
  chown root:naive "$CONFIG"
  chmod 640 "$CONFIG"
}

verify_tunnel() {
  local direct proxied
  direct="$(curl -fsS --max-time 15 https://api.ipify.org || echo '')"
  proxied="$(curl -fsS --max-time 20 --socks5-hostname "127.0.0.1:${SOCKS_PORT}" https://api.ipify.org || echo '')"

  if [[ -z "$proxied" ]]; then
    warn "через прокси запрос не прошёл — проверьте реквизиты и доступность ${DOMAIN}:${PORT}"
    warn "журнал: journalctl -u ${SERVICE} -n 50"
    return 1
  fi
  if [[ -n "$direct" && "$proxied" == "$direct" ]]; then
    warn "IP через прокси совпал с прямым ($proxied) — трафик, похоже, идёт мимо"
    return 1
  fi
  info "работает: напрямую ${direct:-?}, через прокси $proxied"
  return 0
}

ask_credentials() {
  [[ -n "$LINK" ]] && { parse_link "$LINK" || die "не разобрал ссылку. Ожидается naive+https://логин:пароль@домен:443"; return; }
  [[ -n "$DOMAIN" && -n "$USERNAME" && -n "$PASSWORD" ]] && { PORT="${PORT:-443}"; return; }

  [[ -t 0 ]] || die "нет интерактивного ввода — передайте --link или --domain/--user/--password.
    Используйте bash <(curl -fsSL ...), а не curl ... | bash"

  echo "Вставьте ссылку целиком или нажмите Enter, чтобы ввести по частям."
  read -rp "Ссылка: " LINK
  if [[ -n "$LINK" ]]; then
    parse_link "$LINK" || die "не разобрал ссылку. Ожидается naive+https://логин:пароль@домен:443"
  else
    while [[ -z "$DOMAIN" ]];   do read -rp "Домен прокси: " DOMAIN; done
    while [[ -z "$USERNAME" ]]; do read -rp "Логин: " USERNAME; done
    while [[ -z "$PASSWORD" ]]; do read -rsp "Пароль: " PASSWORD; echo; done
    read -rp "Порт [443]: " _p; PORT="${_p:-443}"
  fi
}

# --- switch / status / test ---------------------------------------------------

if [[ "$CMD" == "switch" ]]; then
  load_env
  OLD_DOMAIN="$DOMAIN"
  # реквизиты спрашиваем заново, порты оставляем прежними
  DOMAIN=""; USERNAME=""; PASSWORD=""; PORT=""
  step "Смена прокси"
  echo "Сейчас: ${OLD_DOMAIN}"
  ask_credentials
  save_env
  write_config
  systemctl restart "$SERVICE"
  sleep 2
  systemctl is-active --quiet "$SERVICE" || {
    journalctl -u "$SERVICE" -n 20 --no-pager >&2
    die "служба не поднялась после смены — журнал выше"
  }
  info "переключено на ${DOMAIN}"
  step "Проверка"
  verify_tunnel || true
  trap - ERR
  exit 0
fi

if [[ "$CMD" == "status" ]]; then
  load_env
  printf '%sТекущий прокси%s\n' "$BOLD" "$OFF"
  printf '  сервер:  %s:%s\n' "$DOMAIN" "$PORT"
  printf '  логин:   %s\n' "$USERNAME"
  masked="$(printf '%*s' $(( ${#PASSWORD} > 2 ? ${#PASSWORD} - 2 : 0 )) '' | tr ' ' '*')"
  printf '  пароль:  %s%s\n' "${PASSWORD:0:2}" "$masked"
  printf '  входы:   socks5 127.0.0.1:%s · http 127.0.0.1:%s\n' "$SOCKS_PORT" "$HTTP_PORT"
  printf '\n%sСлужба%s\n' "$BOLD" "$OFF"
  if systemctl is-active --quiet "$SERVICE"; then
    printf '  %sактивна%s, работает %s\n' "$GREEN" "$OFF" \
      "$(systemctl show -p ActiveEnterTimestamp --value "$SERVICE" | cut -d' ' -f2-3)"
  else
    printf '  %sне запущена%s\n' "$RED" "$OFF"
  fi
  trap - ERR
  exit 0
fi

if [[ "$CMD" == "test" ]]; then
  load_env
  step "Проверка туннеля"
  if verify_tunnel; then trap - ERR; exit 0; else trap - ERR; exit 1; fi
fi

# --- удаление -----------------------------------------------------------------

if [[ "$CMD" == "uninstall" ]]; then
  step "Удаление"
  systemctl disable --now "$SERVICE" 2>/dev/null || true
  rm -f "/etc/systemd/system/${SERVICE}.service"
  systemctl daemon-reload
  rm -rf "$CONF_DIR" "$BIN" "$MANAGER"
  [[ -f /etc/environment ]] && sed -i '/# naive-connect/,+3d' /etc/environment 2>/dev/null || true
  id -u naive >/dev/null 2>&1 && userdel naive 2>/dev/null || true
  info "клиент удалён"
  trap - ERR
  exit 0
fi

# --- установка ----------------------------------------------------------------

case "$(uname -m)" in
  x86_64|amd64)  ARCH="x64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  armv7l|armv6l) ARCH="arm" ;;
  i386|i686)     ARCH="x86" ;;
  riscv64)       ARCH="riscv64" ;;
  *) die "неподдерживаемая архитектура: $(uname -m)" ;;
esac

SOCKS_PORT="${SOCKS_PORT:-1080}"
HTTP_PORT="${HTTP_PORT:-8080}"

step "Реквизиты прокси"
ask_credentials
[[ "$PORT" =~ ^[0-9]+$ ]] || die "порт должен быть числом: $PORT"
info "цель: ${USERNAME}@${DOMAIN}:${PORT}"

if [[ -z "$SET_ENV" ]]; then
  if [[ -t 0 ]]; then
    read -rp "Прописать http_proxy в /etc/environment? [y/N]: " _e
    [[ "$_e" =~ ^[YyДд]$ ]] && SET_ENV=1 || SET_ENV=0
  else
    SET_ENV=0
  fi
fi

step "Клиент naive"
export DEBIAN_FRONTEND=noninteractive
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq curl ca-certificates tar xz-utils >/dev/null
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y -q curl ca-certificates tar xz >/dev/null
fi

# Читаем ответ целиком, а не через конвейер: grep -m1 закрывает канал после
# первого совпадения, curl падает с ошибкой записи, и при pipefail это роняло установку.
RELEASE_JSON="$(curl -fsSL --max-time 30 https://api.github.com/repos/klzgrad/naiveproxy/releases/latest)" \
  || die "не удалось получить список релизов naiveproxy"
TAG="$(grep -m1 '"tag_name"' <<<"$RELEASE_JSON" | cut -d'"' -f4)"
[[ -n "$TAG" ]] || die "не удалось узнать версию клиента"
info "версия $TAG"

TMP="$(mktemp -d)"
ASSET="naiveproxy-${TAG}-linux-${ARCH}.tar.xz"
curl -fsSL --max-time 300 -o "$TMP/n.tar.xz" \
  "https://github.com/klzgrad/naiveproxy/releases/download/${TAG}/${ASSET}" \
  || die "не скачался ${ASSET}"
tar -xJf "$TMP/n.tar.xz" -C "$TMP"
FOUND="$(find "$TMP" -name naive -type f -print -quit)"
[[ -n "$FOUND" ]] || die "в архиве нет бинарника naive"
install -m 0755 "$FOUND" "$BIN"
rm -rf "$TMP"
info "$("$BIN" --version 2>&1 | head -1)"

step "Настройка"
id -u naive >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin naive
mkdir -p "$CONF_DIR"
save_env
write_config

cat > "/etc/systemd/system/${SERVICE}.service" <<EOF
[Unit]
Description=NaiveProxy client
After=network-online.target
Wants=network-online.target

[Service]
User=naive
Group=naive
ExecStart=${BIN} ${CONFIG}
Restart=always
RestartSec=5s
LimitNOFILE=1048576
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE" >/dev/null 2>&1
systemctl restart "$SERVICE"
sleep 2
systemctl is-active --quiet "$SERVICE" || {
  journalctl -u "$SERVICE" -n 30 --no-pager >&2
  die "служба не поднялась — журнал выше"
}
info "служба работает"

# Кладём себя в систему, чтобы смена прокси была одной командой.
# При запуске через bash <(curl ...) $0 — это /dev/fd/NN, копировать нечего,
# поэтому в таком случае скачиваем свежую копию.
if [[ -f "$0" && -r "$0" ]]; then
  install -m 0755 "$0" "$MANAGER"
else
  curl -fsSL --max-time 60 -o "$MANAGER" "$SELF_URL" && chmod 755 "$MANAGER"
fi
if [[ -x "$MANAGER" ]]; then
  info "команда naive-connect установлена"
else
  warn "не удалось поставить команду naive-connect — менять прокси придётся переустановкой"
fi

if [[ "$SET_ENV" -eq 1 ]]; then
  sed -i '/# naive-connect/,+3d' /etc/environment 2>/dev/null || true
  cat >> /etc/environment <<EOF
# naive-connect
http_proxy="http://127.0.0.1:${HTTP_PORT}"
https_proxy="http://127.0.0.1:${HTTP_PORT}"
no_proxy="localhost,127.0.0.1,::1"
EOF
  info "переменные записаны в /etc/environment (применятся при следующем входе)"
fi

step "Проверка"
verify_tunnel || true

trap - ERR
cat <<EOF

${BOLD}Готово.${OFF}

  SOCKS5   127.0.0.1:${SOCKS_PORT}
  HTTP     127.0.0.1:${HTTP_PORT}

Смена прокси, когда этот перестанет работать:

  ${BOLD}naive-connect switch${OFF}

Ещё команды:

  naive-connect status      куда смотрит сейчас
  naive-connect test        проверить туннель
  naive-connect uninstall   удалить

${DIM}Реквизиты: ${ENV_FILE} и ${CONFIG}, доступ только root.
Журнал службы: journalctl -u ${SERVICE} -f${OFF}

EOF
