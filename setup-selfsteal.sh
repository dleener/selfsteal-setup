#!/usr/bin/env bash
#
# setup-selfsteal.sh — настройка SelfSteal для Xray Reality (3x-ui)
#
# Два режима:
#   1. Под ключ: ставит панель 3x-ui, настраивает SelfSteal и создаёт готовое
#      подключение VLESS Reality (ссылка и QR-код для клиента)
#   2. Только SelfSteal для уже установленной панели — Target и SNI
#      в 3x-ui меняются вручную
#
# Что делает SelfSteal-часть:
#   1. Проверяет, что DNS-запись домена указывает на этот сервер
#   2. Ставит nginx и certbot
#   3. Создаёт страницу-заглушку (локально для Reality и на порту 80)
#   4. Получает сертификат Let's Encrypt для домена
#   5. Поднимает nginx с TLS на 127.0.0.1:<порт> — сюда будет смотреть Reality
#   6. Настраивает перезапуск nginx после продления сертификата
#   7. Проверяет результат и печатает, что вписать в 3x-ui
#
# Использование:
#   sudo bash setup-selfsteal.sh                                        # меню с вопросами
#   sudo bash setup-selfsteal.sh -d nl2.example.com -e you@example.com  # режим 2 без вопросов
#
set -euo pipefail

# ---------- параметры по умолчанию ----------
PORT=8001
DOMAIN=""
EMAIL=""
SITE_NAME="ProxHub"
SKIP_DNS_CHECK=0
MODE="selfsteal"      # selfsteal | full (под ключ)
INTERACTIVE=0
REALITY_PORT=443
CLIENT_NAME="user1"
PANEL_PORT=""
PANEL_PATH=""
PANEL_USER=""
PANEL_PASS=""

WEBROOT="/var/www/selfsteal"
HOOK="/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh"

# режим «под ключ»
XUI_DIR="/usr/local/x-ui"
XUI_INSTALLER="https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh"
XUI_HOOK="/etc/letsencrypt/renewal-hooks/deploy/restart-x-ui.sh"
STATE="/etc/x-ui/selfsteal-setup.env"
SUMMARY="/root/3x-ui-selfsteal.txt"
INSTALL_LOG="/var/log/selfsteal-3x-ui-install.log"

# ---------- оформление вывода ----------
if [ -t 1 ]; then
  G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; B=$'\e[1m'; N=$'\e[0m'
else
  G=""; Y=""; R=""; B=""; N=""
fi
step() { printf '\n%s==> %s%s\n' "$B" "$*" "$N"; }
ok()   { printf '%s  ✓ %s%s\n' "$G" "$*" "$N"; }
warn() { printf '%s  ! %s%s\n' "$Y" "$*" "$N"; }
die()  { printf '%s  ✗ %s%s\n' "$R" "$*" "$N" >&2; exit 1; }

usage() {
  cat <<EOF
Использование:
  $0                          меню с вопросами (в том числе установка 3x-ui под ключ)
  $0 -d <домен> -e <email> [параметры]   только SelfSteal, без вопросов

Обязательные:
  -d, --domain   домен, например nl2.proxhub.ru
  -e, --email    почта для уведомлений Let's Encrypt

Необязательные:
  -p, --port     локальный порт для Reality (по умолчанию 8001)
  -n, --name     название на странице-заглушке (по умолчанию ProxHub)
  --skip-dns-check  не проверять, что домен указывает на этот сервер
  -h, --help     эта справка
EOF
}

need_value() { [ $# -ge 2 ] && [ -n "$2" ] || die "Параметру $1 нужно значение"; }

valid_domain() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]; }
valid_email()  { [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; }
port_busy()    { [ -n "$(ss -tlnH "( sport = :$1 )" 2>/dev/null)" ]; }
rand_str()     { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-"$1"; }

# Сверяет A-запись домена с адресами сервера. Заполняет RESOLVED и MATCH;
# при ошибке кладёт текст в DNS_ERR и возвращает 1.
dns_points_here() {
  MATCH=""
  RESOLVED=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u || true)
  if [ -z "$RESOLVED" ]; then
    DNS_ERR="У домена $DOMAIN нет A-записи. Создайте её и подождите пару минут."
    return 1
  fi

  LOCAL_IPS=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)
  PUBLIC_IP=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
  ALL_IPS=$(printf '%s\n%s\n' "$LOCAL_IPS" "$PUBLIC_IP" | grep -v '^$' | sort -u)

  for ip in $RESOLVED; do
    if printf '%s\n' "$ALL_IPS" | grep -qx "$ip"; then MATCH="$ip"; fi
  done

  if [ -z "$MATCH" ]; then
    printf '  Домен указывает на: %s\n' "$(echo $RESOLVED)"
    printf '  Адреса этого сервера: %s\n' "$(echo $ALL_IPS)"
    DNS_ERR="Домен смотрит не на этот сервер. Проверьте A-запись. В Cloudflare должен быть режим DNS only (серая тучка)."
    return 1
  fi
}

# ---------- вопросы (запуск без параметров) ----------
# ask "Вопрос" ["по умолчанию"] — ответ в $REPLY, Enter = значение по умолчанию
ask() {
  local hint=""
  [ -z "${2:-}" ] || hint=" [$2]"
  read -r -p "  ${1}${hint}: " REPLY </dev/tty
  REPLY="${REPLY:-${2:-}}"
}

confirm() {
  local a
  read -r -p "  $1 [Y/n]: " a </dev/tty
  case "$a" in ""|[Yy]*|д*|Д*) return 0 ;; *) return 1 ;; esac
}

ask_domain() {
  while :; do
    ask "Домен (например, nl2.proxhub.ru)" "$DOMAIN"
    REPLY="${REPLY#http://}"; REPLY="${REPLY#https://}"; REPLY="${REPLY%%/*}"
    DOMAIN=$(printf '%s' "$REPLY" | tr '[:upper:]' '[:lower:]')
    valid_domain "$DOMAIN" && return
    warn "Это не похоже на домен. Нужно что-то вроде nl2.proxhub.ru — без https:// и пробелов"
  done
}

check_dns_interactive() {
  while :; do
    step "Проверка DNS"
    if dns_points_here; then
      ok "$DOMAIN → $MATCH"
      return
    fi
    warn "$DNS_ERR"
    cat <<EOF

  Что делать:
    1) Проверить ещё раз (если запись только что создана — подождите 1–2 минуты)
    2) Ввести другой домен
    3) Продолжить без проверки (только если сервер за NAT и IP точно верный)
    0) Выйти
EOF
    ask "Ваш выбор" 1
    case "$REPLY" in
      1) ;;
      2) ask_domain ;;
      3) SKIP_DNS_CHECK=1; warn "Проверка DNS пропущена"; return ;;
      0) exit 0 ;;
      *) warn "Введите 1, 2, 3 или 0" ;;
    esac
  done
}

interactive_setup() {
  { : </dev/tty; } 2>/dev/null || { usage; die "Нет терминала для вопросов. Запустите с параметрами -d и -e"; }

  cat <<EOF

${B}SelfSteal для Xray Reality${N}

  SelfSteal — это когда VPN-сервер показывает проверяющим обычный сайт
  на вашем домене с настоящим сертификатом, а не чужой сайт.

  Что будем делать:
    1) Установить всё под ключ: панель 3x-ui + SelfSteal + готовое подключение
       Для чистого сервера. В конце получите ссылку и QR-код для телефона.
    2) Только SelfSteal для уже установленной панели 3x-ui
       Target и SNI в панели поменяете сами — скрипт подскажет, что вписать.
    0) Выход

EOF
  while :; do
    ask "Ваш выбор" 1
    case "$REPLY" in
      1) MODE=full; break ;;
      2) MODE=selfsteal; break ;;
      0) exit 0 ;;
      *) warn "Введите 1, 2 или 0" ;;
    esac
  done

  if [ "$MODE" = full ] && [ -x "$XUI_DIR/x-ui" ] && [ ! -f "$STATE" ]; then
    warn "Панель 3x-ui на этом сервере уже установлена (не этим скриптом)."
    printf '  Чтобы не сломать её настройки, установка под ключ здесь не подойдёт.\n'
    printf '  Режим 2 настроит SelfSteal, а в панели останется поменять два поля.\n\n'
    confirm "Перейти к режиму 2?" || exit 0
    MODE=selfsteal
  fi

  # Повторный запуск под ключ: данные прошлой установки — значения по умолчанию
  if [ "$MODE" = full ] && [ -f "$STATE" ]; then
    # shellcheck source=/dev/null
    . "$STATE"
    ok "Найдены данные прошлой установки ($STATE), используем их"
  fi

  cat <<EOF

${B}Что понадобится${N}
  • Домен или поддомен, A-запись которого указывает на IP этого сервера.
    В Cloudflare — режим DNS only (серая тучка), иначе сертификат не выдадут.
  • Почта — на неё Let's Encrypt пишет, если с сертификатом что-то не так.

  В квадратных скобках — значение по умолчанию, чтобы его принять, нажмите Enter.

EOF
  ask_domain
  check_dns_interactive

  # Локальный порт не спрашиваем: при повторном запуске берём прежний, иначе первый свободный
  local conf="/etc/nginx/conf.d/selfsteal-${DOMAIN}.conf" legacy="/etc/nginx/conf.d/selfsteal.conf" old="" want="$PORT"
  if [ -f "$conf" ]; then
    old=$(sed -n 's/.*listen 127\.0\.0\.1:\([0-9]*\) ssl;.*/\1/p' "$conf" | head -n1)
  elif [ -f "$legacy" ] && grep -q "server_name[[:space:]]\+${DOMAIN};" "$legacy"; then
    old=$(sed -n 's/.*listen 127\.0\.0\.1:\([0-9]*\) ssl;.*/\1/p' "$legacy" | head -n1)
  fi
  if [ -n "$old" ]; then
    PORT="$old"
  else
    while port_busy "$PORT"; do PORT=$((PORT + 1)); done
    [ "$PORT" = "$want" ] || warn "Порт $want занят, для SelfSteal будет использован $PORT"
  fi

  echo
  while :; do
    ask "Почта для Let's Encrypt" "$EMAIL"
    EMAIL="$REPLY"
    valid_email "$EMAIL" && break
    warn "Это не похоже на почту. Пример: you@example.com"
  done

  if [ "$MODE" = full ] && [ ! -f "$STATE" ]; then
    while :; do
      ask "Порт для подключения к VPN (443 — лучший вариант)" "$REALITY_PORT"
      if ! [[ "$REPLY" =~ ^[0-9]+$ ]] || [ "$REPLY" -lt 1 ] || [ "$REPLY" -gt 65535 ] || [ "$REPLY" = "$PORT" ]; then
        warn "Нужно число от 1 до 65535 (кроме $PORT — он для SelfSteal)"
        continue
      fi
      if port_busy "$REPLY"; then
        ss -tlnpH "( sport = :$REPLY )" || true
        warn "Порт $REPLY уже занят другой программой. Освободите его или выберите другой, например 8443"
        continue
      fi
      REALITY_PORT="$REPLY"
      break
    done
    while :; do
      ask "Имя первого клиента (латиница, цифры, - и _)" "$CLIENT_NAME"
      if [[ "$REPLY" =~ ^[A-Za-z0-9_-]{1,32}$ ]]; then CLIENT_NAME="$REPLY"; break; fi
      warn "Только латинские буквы, цифры, - и _, не длиннее 32 символов"
    done
  fi

  ask "Название сайта на странице-заглушке" "$SITE_NAME"
  SITE_NAME="$REPLY"

  printf '\n%sПроверьте, всё ли верно:%s\n' "$B" "$N"
  if [ "$MODE" = full ]; then
    printf '  Режим:            под ключ (3x-ui + SelfSteal + подключение)\n'
  else
    printf '  Режим:            только SelfSteal\n'
  fi
  printf '  Домен:            %s\n' "$DOMAIN"
  printf '  Почта:            %s\n' "$EMAIL"
  if [ "$MODE" = full ]; then
    printf '  Порт VPN:         %s\n' "$REALITY_PORT"
    printf '  Клиент:           %s\n' "$CLIENT_NAME"
  fi
  printf '  Сайт-заглушка:    %s\n' "$SITE_NAME"
  printf '  Локальный порт:   %s (сюда смотрит Reality)\n\n' "$PORT"
  confirm "Начинаем?" || exit 0
  printf '  Дальше всё автоматически, это займёт 2–5 минут.\n'
}

# ---------- разбор аргументов ----------
[ $# -gt 0 ] || INTERACTIVE=1

while [ $# -gt 0 ]; do
  case "$1" in
    -d|--domain) need_value "$@"; DOMAIN="$2"; shift 2 ;;
    -e|--email)  need_value "$@"; EMAIL="$2";  shift 2 ;;
    -p|--port)   need_value "$@"; PORT="$2";   shift 2 ;;
    -n|--name)   need_value "$@"; SITE_NAME="$2"; shift 2 ;;
    --skip-dns-check) SKIP_DNS_CHECK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "Неизвестный параметр: $1" ;;
  esac
done

# ---------- проверка входных данных ----------
[ "$INTERACTIVE" -eq 1 ] || step "Проверка параметров"

[ "$(id -u)" -eq 0 ] || die "Запустите от root (через sudo)"
command -v apt-get >/dev/null || die "Скрипт рассчитан на Ubuntu/Debian (нужен apt-get)"

if [ "$INTERACTIVE" -eq 1 ]; then
  interactive_setup
else
  [ -n "$DOMAIN" ] || { usage; die "Не указан домен (-d)"; }
  [ -n "$EMAIL" ]  || { usage; die "Не указана почта (-e)"; }

  valid_domain "$DOMAIN" || die "Некорректный домен: $DOMAIN"
  valid_email "$EMAIL"   || die "Некорректная почта: $EMAIL"
  [[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1024 ] && [ "$PORT" -le 65535 ] \
    || die "Порт должен быть числом от 1024 до 65535"

  ok "Домен: $DOMAIN"
  ok "Почта: $EMAIL"
  ok "Локальный порт: $PORT"

  # ---------- DNS ----------
  step "Проверка DNS"

  if [ "$SKIP_DNS_CHECK" -eq 1 ]; then
    RESOLVED=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u || true)
    warn "Проверка DNS пропущена (--skip-dns-check)"
  else
    dns_points_here || die "$DNS_ERR"
    ok "$DOMAIN → $MATCH"
  fi
fi

CONF="/etc/nginx/conf.d/selfsteal-${DOMAIN}.conf"
CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"

# ---------- старые ручные настройки ----------
REPLACING=0
[ -f "$CONF" ] && REPLACING=1

OLD_CONF="/etc/nginx/conf.d/selfsteal.conf"
if [ -f "$OLD_CONF" ] && grep -q "server_name[[:space:]]\+${DOMAIN};" "$OLD_CONF"; then
  BACKUP="${OLD_CONF}.bak-$(date +%Y%m%d-%H%M%S)"
  mv "$OLD_CONF" "$BACKUP"
  warn "Найден старый конфиг для этого домена, убран в $BACKUP"
  REPLACING=1
fi

# ---------- порты ----------
step "Проверка портов"

if [ "$REPLACING" -eq 0 ] && port_busy "$PORT"; then
  ss -tlnpH "( sport = :$PORT )" || true
  die "Порт $PORT уже занят. Выберите другой: -p 8002"
fi
ok "Порт $PORT свободен"

PORT80=$(ss -tlnpH "( sport = :80 )" 2>/dev/null || true)
if [ -n "$PORT80" ] && ! printf '%s' "$PORT80" | grep -q nginx; then
  printf '%s\n' "$PORT80"
  die "Порт 80 занят не nginx'ом. Он нужен Let's Encrypt для проверки домена."
fi
ok "Порт 80 доступен"

if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 80/tcp >/dev/null
  ok "В ufw открыт порт 80"
fi

# ---------- пакеты ----------
step "Установка nginx и certbot"

PKGS=(nginx certbot python3-certbot-nginx)
if [ "$MODE" = full ]; then PKGS+=(jq qrencode); fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq "${PKGS[@]}" >/dev/null
systemctl enable --now nginx >/dev/null 2>&1
ok "nginx: $(nginx -v 2>&1 | cut -d/ -f2)"
ok "certbot: $(certbot --version 2>&1 | awk '{print $2}')"

# ---------- страница-заглушка ----------
step "Страница-заглушка"

mkdir -p "$WEBROOT"
cat > "$WEBROOT/index.html" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${SITE_NAME}</title>
<style>
  body { margin:0; min-height:100vh; display:flex; align-items:center;
         justify-content:center; font-family:system-ui,-apple-system,sans-serif;
         background:#0f1115; color:#e6e8eb; }
  .box { text-align:center; padding:2rem; }
  h1 { font-size:2.5rem; margin:0 0 .5rem; letter-spacing:-.02em; }
  p  { color:#8b9199; margin:0; }
</style>
</head>
<body>
  <div class="box">
    <h1>${SITE_NAME}</h1>
    <p>Site under construction</p>
  </div>
</body>
</html>
EOF
ok "Создана $WEBROOT/index.html"

# Та же страница на порту 80 вместо «Welcome to nginx!»
if [ -f /var/www/html/index.html ] && ! cmp -s "$WEBROOT/index.html" /var/www/html/index.html; then
  cp /var/www/html/index.html "/var/www/html/index.html.bak-$(date +%Y%m%d-%H%M%S)"
fi
mkdir -p /var/www/html
cp "$WEBROOT/index.html" /var/www/html/index.html
ok "Заглушка выставлена на порт 80"

# ---------- сертификат ----------
step "Сертификат Let's Encrypt"

certbot certonly --nginx -d "$DOMAIN" \
  --non-interactive --agree-tos -m "$EMAIL" \
  --keep-until-expiring \
  || die "certbot не смог получить сертификат. Проверьте DNS и доступность порта 80 снаружи."

[ -f "$CERT_DIR/fullchain.pem" ] || die "Сертификат не найден в $CERT_DIR"
EXPIRES=$(openssl x509 -enddate -noout -in "$CERT_DIR/fullchain.pem" | cut -d= -f2)
ok "Сертификат действует до: $EXPIRES"

# ---------- nginx для Reality ----------
step "Конфиг nginx для Reality"

cat > "$CONF" <<EOF
# Создано setup-selfsteal.sh — цель (target) для Xray Reality
server {
    listen 127.0.0.1:${PORT} ssl;
    server_name ${DOMAIN};

    ssl_certificate     ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;

    root ${WEBROOT};
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

if ! nginx -t >/dev/null 2>&1; then
  nginx -t || true
  rm -f "$CONF"
  die "Ошибка в конфиге nginx, изменения откачены"
fi
systemctl reload nginx
ok "Создан $CONF"

# ---------- хук продления ----------
step "Перезапуск nginx после продления сертификата"

mkdir -p "$(dirname "$HOOK")"
cat > "$HOOK" <<'EOF'
#!/bin/sh
systemctl reload nginx
EOF
chmod +x "$HOOK"
ok "Создан $HOOK"

# ---------- проверки ----------
step "Проверка результата"

SUBJECT=$(echo | timeout 10 openssl s_client -connect "127.0.0.1:${PORT}" -servername "$DOMAIN" 2>/dev/null \
  | openssl x509 -noout -subject 2>/dev/null || true)
if printf '%s' "$SUBJECT" | grep -q "$DOMAIN"; then
  ok "127.0.0.1:$PORT предъявляет сертификат $DOMAIN"
else
  die "127.0.0.1:$PORT не отдаёт нужный сертификат. Получено: ${SUBJECT:-ничего}"
fi

if curl -fsS --max-time 5 "http://127.0.0.1/" 2>/dev/null | grep -q "$SITE_NAME"; then
  ok "Порт 80 отдаёт заглушку"
else
  warn "Порт 80 отдаёт что-то другое — проверьте вручную"
fi

if certbot renew --dry-run --cert-name "$DOMAIN" >/dev/null 2>&1; then
  ok "Пробное продление прошло успешно"
else
  warn "Пробное продление не прошло. Проверьте: certbot renew --dry-run"
fi

# ---------- под ключ: панель 3x-ui ----------
save_state() {
  mkdir -p "$(dirname "$STATE")"
  (
    umask 077
    for v in DOMAIN EMAIL PORT SITE_NAME REALITY_PORT CLIENT_NAME PANEL_PORT PANEL_PATH PANEL_USER PANEL_PASS; do
      printf '%s=%q\n' "$v" "${!v}"
    done > "$STATE"
  )
}

free_port() {
  local p
  while :; do
    p=$(shuf -i 20000-60000 -n 1)
    if [ "$p" != "$REALITY_PORT" ] && [ "$p" != "$PORT" ] && ! port_busy "$p"; then
      echo "$p"
      return
    fi
  done
}

install_xui() {
  step "Установка панели 3x-ui"

  if [ -z "$PANEL_PORT" ]; then
    PANEL_USER=$(rand_str 10)
    PANEL_PASS=$(rand_str 16)
    PANEL_PATH=$(rand_str 16)
    PANEL_PORT=$(free_port)
  fi
  # Сохраняем до установки: если она оборвётся, повторный запуск возьмёт те же данные
  save_state

  if [ -x "$XUI_DIR/x-ui" ]; then
    ok "3x-ui уже установлена, переустановка не нужна"
  else
    printf '  Скачиваю и ставлю последнюю версию, это 1–3 минуты...\n'
    local tmp
    tmp=$(mktemp -d)
    curl -fsSL "$XUI_INSTALLER" -o "$tmp/install.sh" \
      || die "Не удалось скачать установщик 3x-ui с GitHub. Проверьте интернет на сервере и запустите скрипт ещё раз."
    if ! XUI_NONINTERACTIVE=1 XUI_SSL_MODE=none \
         XUI_USERNAME="$PANEL_USER" XUI_PASSWORD="$PANEL_PASS" \
         XUI_PANEL_PORT="$PANEL_PORT" XUI_WEB_BASE_PATH="$PANEL_PATH" \
         bash "$tmp/install.sh" </dev/null >"$INSTALL_LOG" 2>&1; then
      tail -n 20 "$INSTALL_LOG" || true
      rm -rf "$tmp"
      die "Установщик 3x-ui завершился с ошибкой. Полный лог: $INSTALL_LOG"
    fi
    rm -rf "$tmp"
    [ -x "$XUI_DIR/x-ui" ] || die "3x-ui не появилась в $XUI_DIR. Лог установки: $INSTALL_LOG"
    ok "3x-ui установлена, версия $("$XUI_DIR/x-ui" -v 2>/dev/null || echo 'неизвестна')"
  fi

  "$XUI_DIR/x-ui" setting -username "$PANEL_USER" -password "$PANEL_PASS" \
    -port "$PANEL_PORT" -webBasePath "$PANEL_PATH" >/dev/null
  "$XUI_DIR/x-ui" cert -webCert "$CERT_DIR/fullchain.pem" -webCertKey "$CERT_DIR/privkey.pem" >/dev/null
  systemctl restart x-ui
  ok "Логин, пароль и HTTPS для панели настроены"

  mkdir -p "$(dirname "$XUI_HOOK")"
  cat > "$XUI_HOOK" <<'EOF'
#!/bin/sh
systemctl restart x-ui
EOF
  chmod +x "$XUI_HOOK"
  ok "Создан $XUI_HOOK — панель подхватит продлённый сертификат"

  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "$REALITY_PORT/tcp" >/dev/null
    ufw allow "$PANEL_PORT/tcp" >/dev/null
    ok "В ufw открыты порты $REALITY_PORT и $PANEL_PORT"
  fi

  PANEL_URL="https://${DOMAIN}:${PANEL_PORT}/${PANEL_PATH}/"
  API="https://${DOMAIN}:${PANEL_PORT}/${PANEL_PATH}/panel/api"

  local i up=0
  for i in $(seq 1 30); do
    if curl -s -o /dev/null --max-time 3 --resolve "${DOMAIN}:${PANEL_PORT}:127.0.0.1" "$PANEL_URL"; then
      up=1
      break
    fi
    sleep 1
  done
  [ "$up" -eq 1 ] || die "Панель не отвечает по HTTPS на порту $PANEL_PORT. Проверьте: systemctl status x-ui"
  ok "Панель отвечает по HTTPS"

  API_TOKEN=$("$XUI_DIR/x-ui" setting -getApiToken -tokenName selfsteal-setup 2>/dev/null \
    | awk '/apiToken:/ {print $2}' | tail -n1 || true)
  [ -n "$API_TOKEN" ] || manual_inbound "не удалось получить API-токен панели"
}

# Запрос к API панели: $1 — путь после /panel/api/, дальше — параметры curl
api() {
  local path="$1"
  shift
  curl -sS --max-time 20 --resolve "${DOMAIN}:${PANEL_PORT}:127.0.0.1" \
    -H "Authorization: Bearer $API_TOKEN" -H "Accept: application/json" \
    "$API/$path" "$@"
}

# Если API панели повёл себя неожиданно — не бросаем человека, а говорим, что сделать руками
manual_inbound() {
  warn "Панель установлена, но подключение не создано автоматически: $1"
  cat <<EOF

${B}Панель 3x-ui${N}
  Адрес:   $PANEL_URL
  Логин:   $PANEL_USER
  Пароль:  $PANEL_PASS

${B}Создайте подключение вручную:${N} Inbounds → Add Inbound
  Protocol: vless, Port: $REALITY_PORT, Security: Reality
  Target (Dest):      127.0.0.1:$PORT
  SNI (Server Names): $DOMAIN
  Нажмите Get New Cert, у клиента выберите Flow: xtls-rprx-vision и сохраните.

  Данные для входа сохранены в $STATE
EOF
  exit 1
}

setup_inbound() {
  step "Подключение VLESS Reality"

  local list existing settings stream target keys priv body resp msg
  list=$(api inbounds/list || true)
  [ "$(jq -r '.success // false' <<<"$list" 2>/dev/null || true)" = true ] \
    || manual_inbound "панель не отдала список подключений"

  existing=$(jq -c --argjson p "$REALITY_PORT" '[.obj[]? | select(.port == $p)][0] // empty' <<<"$list")

  if [ -n "$existing" ]; then
    # Повторный запуск: подключение уже есть, достаём из него данные для ссылки
    settings=$(jq -c '.settings | if type == "string" then fromjson else . end' <<<"$existing")
    stream=$(jq -c '.streamSettings | if type == "string" then fromjson else . end' <<<"$existing")
    [ "$(jq -r '.security' <<<"$stream")" = reality ] \
      || manual_inbound "порт $REALITY_PORT в панели уже занят другим подключением"
    UUID=$(jq -r '.clients[0].id // empty' <<<"$settings")
    CLIENT_NAME=$(jq -r '.clients[0].email // empty' <<<"$settings")
    PUBLIC_KEY=$(jq -r '.realitySettings.settings.publicKey // empty' <<<"$stream")
    SHORT_ID=$(jq -r '.realitySettings.shortIds[0] // empty' <<<"$stream")
    [ -n "$UUID" ] && [ -n "$PUBLIC_KEY" ] && [ -n "$SHORT_ID" ] \
      || manual_inbound "в подключении на порту $REALITY_PORT нет клиента или ключей"
    ok "Подключение на порту $REALITY_PORT уже есть, новое не создаю"
    target=$(jq -r '.realitySettings.target // .realitySettings.dest // empty' <<<"$stream")
    [ "$target" = "127.0.0.1:$PORT" ] \
      || warn "У него Target = $target, а SelfSteal слушает 127.0.0.1:$PORT — поправьте в панели"
    jq -e --arg d "$DOMAIN" '.realitySettings.serverNames | index($d)' <<<"$stream" >/dev/null \
      || warn "В его SNI нет $DOMAIN — добавьте домен в Server Names в панели"
  else
    keys=$(api server/getNewX25519Cert || true)
    priv=$(jq -r '.obj.privateKey // empty' <<<"$keys" 2>/dev/null || true)
    PUBLIC_KEY=$(jq -r '.obj.publicKey // empty' <<<"$keys" 2>/dev/null || true)
    [ -n "$priv" ] && [ -n "$PUBLIC_KEY" ] || manual_inbound "панель не выдала ключи Reality"

    UUID=$(cat /proc/sys/kernel/random/uuid)
    SHORT_ID=$(openssl rand -hex 8)

    # settings/streamSettings/sniffing — JSON-строки: такой формат понимают и старые, и новые версии панели
    body=$(jq -n \
      --arg remark "selfsteal-$DOMAIN" --argjson port "$REALITY_PORT" \
      --arg uuid "$UUID" --arg email "$CLIENT_NAME" --arg sub "$(openssl rand -hex 8)" \
      --arg target "127.0.0.1:$PORT" --arg domain "$DOMAIN" \
      --arg priv "$priv" --arg pub "$PUBLIC_KEY" --arg sid "$SHORT_ID" '{
        enable: true, remark: $remark, listen: "", port: $port, protocol: "vless",
        expiryTime: 0, total: 0,
        settings: ({
          clients: [{ id: $uuid, flow: "xtls-rprx-vision", email: $email, enable: true,
                      subId: $sub, limitIp: 0, totalGB: 0, expiryTime: 0 }],
          decryption: "none", fallbacks: []
        } | tojson),
        streamSettings: ({
          network: "tcp", security: "reality",
          realitySettings: {
            show: false, xver: 0, target: $target, serverNames: [$domain],
            privateKey: $priv, shortIds: [$sid],
            settings: { publicKey: $pub, fingerprint: "chrome", serverName: "", spiderX: "/" }
          },
          tcpSettings: { acceptProxyProtocol: false, header: { type: "none" } }
        } | tojson),
        sniffing: ({ enabled: true, destOverride: ["http", "tls", "quic"] } | tojson)
      }')

    resp=$(api inbounds/add -H "Content-Type: application/json" --data "$body" || true)
    if [ "$(jq -r '.success // false' <<<"$resp" 2>/dev/null || true)" != true ]; then
      msg=$(jq -r '.msg // empty' <<<"$resp" 2>/dev/null || true)
      manual_inbound "панель ответила: ${msg:-${resp:0:200}}"
    fi
    api server/restartXrayService -X POST >/dev/null || true
    ok "Создано подключение selfsteal-$DOMAIN на порту $REALITY_PORT"
  fi

  local subject="" i
  for i in $(seq 1 15); do
    subject=$(echo | timeout 5 openssl s_client -connect "127.0.0.1:${REALITY_PORT}" -servername "$DOMAIN" 2>/dev/null \
      | openssl x509 -noout -subject 2>/dev/null || true)
    if printf '%s' "$subject" | grep -q "$DOMAIN"; then break; fi
    sleep 1
  done
  if printf '%s' "$subject" | grep -q "$DOMAIN"; then
    ok "Порт $REALITY_PORT предъявляет сертификат $DOMAIN — SelfSteal работает"
  else
    warn "Порт $REALITY_PORT пока не отдаёт сертификат $DOMAIN. Подождите минуту или нажмите в панели Restart Xray"
  fi
}

finish_full() {
  local link text
  link="vless://${UUID}@${DOMAIN}:${REALITY_PORT}?type=tcp&encryption=none&security=reality&pbk=${PUBLIC_KEY}&fp=chrome&sni=${DOMAIN}&sid=${SHORT_ID}&spx=%2F&flow=xtls-rprx-vision#${CLIENT_NAME}"
  text=$(cat <<EOF
Панель 3x-ui
  Адрес:   $PANEL_URL
  Логин:   $PANEL_USER
  Пароль:  $PANEL_PASS

Подключение для клиента «$CLIENT_NAME»
  $link

Как подключиться
  1. Установите приложение: Happ (iPhone, Android, Windows, Mac),
     v2rayNG (Android) или Hiddify (все платформы)
  2. В приложении нажмите «+» и выберите импорт из буфера (скопируйте
     ссылку выше) или сканирование QR-кода (QR ниже)
  3. Включите подключение

Новых клиентов добавляйте в панели, в подключении selfsteal-$DOMAIN.
EOF
)
  (
    umask 077
    { printf '%s\n\n' "$text"; qrencode -t utf8 "$link"; } > "$SUMMARY"
  )

  printf '\n%s%sГотово!%s Всё установлено и настроено.\n\n' "$G" "$B" "$N"
  printf '%s\n\n' "$text"
  qrencode -t ansiutf8 "$link"
  printf '\n  Всё это сохранено в %s — посмотреть снова: cat %s\n' "$SUMMARY" "$SUMMARY"
  printf '  Никому не показывайте пароль от панели и ссылку подключения.\n'
}

if [ "$MODE" = full ]; then
  install_xui
  setup_inbound
  finish_full
  exit 0
fi

# ---------- итог ----------
SERVER_IP="${MATCH:-$(echo "$RESOLVED" | head -n1)}"
SERVER_IP="${SERVER_IP:-<IP сервера>}"

cat <<EOF

${G}${B}Готово.${N} Серверная часть настроена.

${B}Осталось сделать вручную в 3x-ui:${N}
  Inbounds → ваш Reality inbound → редактировать → блок Reality:

    Target (Dest):      127.0.0.1:${PORT}
    SNI (Server Names): ${DOMAIN}

  Ключи, shortIds и клиентов не трогайте. Сохраните.
  Затем обновите подписку в клиенте и проверьте подключение.

${B}Проверка после правки в 3x-ui${N} (подставьте порт Reality):
  echo | openssl s_client -connect ${SERVER_IP}:<порт> -servername ${DOMAIN} 2>/dev/null | openssl x509 -noout -subject -issuer

  Ожидается: subject=CN = ${DOMAIN}, issuer с Let's Encrypt.
EOF
