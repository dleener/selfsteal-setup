#!/usr/bin/env bash
#
# setup-selfsteal.sh — настройка SelfSteal для Xray Reality (3x-ui)
#
# Что делает:
#   1. Проверяет, что DNS-запись домена указывает на этот сервер
#   2. Ставит nginx и certbot
#   3. Создаёт страницу-заглушку (локально для Reality и на порту 80)
#   4. Получает сертификат Let's Encrypt для домена
#   5. Поднимает nginx с TLS на 127.0.0.1:<порт> — сюда будет смотреть Reality
#   6. Настраивает перезапуск nginx после продления сертификата
#   7. Проверяет результат и печатает, что вписать в 3x-ui
#
# Использование:
#   sudo bash setup-selfsteal.sh -d nl2.example.com -e you@example.com
#
set -euo pipefail

# ---------- параметры по умолчанию ----------
PORT=8001
DOMAIN=""
EMAIL=""
SITE_NAME="ProxHub"
SKIP_DNS_CHECK=0

WEBROOT="/var/www/selfsteal"
HOOK="/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh"

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
  $0 -d <домен> -e <email> [параметры]

Обязательные:
  -d, --domain   домен, например nl2.proxhub.tech
  -e, --email    почта для уведомлений Let's Encrypt

Необязательные:
  -p, --port     локальный порт для Reality (по умолчанию 8001)
  -n, --name     название на странице-заглушке (по умолчанию ProxHub)
  --skip-dns-check  не проверять, что домен указывает на этот сервер
  -h, --help     эта справка
EOF
}

need_value() { [ $# -ge 2 ] && [ -n "$2" ] || die "Параметру $1 нужно значение"; }

# ---------- разбор аргументов ----------
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
step "Проверка параметров"

[ "$(id -u)" -eq 0 ] || die "Запустите от root (через sudo)"
command -v apt-get >/dev/null || die "Скрипт рассчитан на Ubuntu/Debian (нужен apt-get)"

[ -n "$DOMAIN" ] || { usage; die "Не указан домен (-d)"; }
[ -n "$EMAIL" ]  || { usage; die "Не указана почта (-e)"; }

[[ "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]] \
  || die "Некорректный домен: $DOMAIN"
[[ "$EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] \
  || die "Некорректная почта: $EMAIL"
[[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1024 ] && [ "$PORT" -le 65535 ] \
  || die "Порт должен быть числом от 1024 до 65535"

CONF="/etc/nginx/conf.d/selfsteal-${DOMAIN}.conf"
CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"

ok "Домен: $DOMAIN"
ok "Почта: $EMAIL"
ok "Локальный порт: $PORT"

# ---------- DNS ----------
step "Проверка DNS"

RESOLVED=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u || true)

if [ "$SKIP_DNS_CHECK" -eq 1 ]; then
  warn "Проверка DNS пропущена (--skip-dns-check)"
else
  [ -n "$RESOLVED" ] || die "У домена $DOMAIN нет A-записи. Создайте её и подождите пару минут."

  LOCAL_IPS=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)
  PUBLIC_IP=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
  ALL_IPS=$(printf '%s\n%s\n' "$LOCAL_IPS" "$PUBLIC_IP" | grep -v '^$' | sort -u)

  MATCH=""
  for ip in $RESOLVED; do
    if printf '%s\n' "$ALL_IPS" | grep -qx "$ip"; then MATCH="$ip"; fi
  done

  if [ -z "$MATCH" ]; then
    printf '  Домен указывает на: %s\n' "$(echo $RESOLVED)"
    printf '  Адреса этого сервера: %s\n' "$(echo $ALL_IPS)"
    die "Домен смотрит не на этот сервер. Проверьте A-запись. В Cloudflare должен быть режим DNS only (серая тучка)."
  fi
  ok "$DOMAIN → $MATCH"
fi

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

if [ "$REPLACING" -eq 0 ] && [ -n "$(ss -tlnH "( sport = :$PORT )" 2>/dev/null)" ]; then
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

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq nginx certbot python3-certbot-nginx >/dev/null
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
