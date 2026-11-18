#!/usr/bin/env bash
# VLESS + XHTTP через Cloudflare CDN: клиенты подключаются к адресам Cloudflare,
# а не к IP сервера, поэтому бан IP сервера не ломает подключение.
# https://github.com/Rodion4365/amnezia-vpn-installer
#
#   curl -fsSL https://raw.githubusercontent.com/Rodion4365/amnezia-vpn-installer/main/cf-vpn.sh | bash -s -- install --domain example.com
#
# Перед запуском: домен добавлен в Cloudflare, A-запись на IP сервера с оранжевым облаком (Proxied).

set -Eeuo pipefail
export LC_ALL=C.UTF-8

REPO_RAW="https://raw.githubusercontent.com/Rodion4365/amnezia-vpn-installer/main/cf-vpn.sh"
XRAY_CONF=/usr/local/etc/xray/config.json
STATE=/usr/local/etc/xray/cf-vpn.env
CLIENTS_DIR="${CF_CLIENTS_DIR:-/root/cf-clients}"
WEBROOT=/var/www/cf-vpn
NGINX_SITE=/etc/nginx/sites-available/cf-vpn
FW_SCRIPT=/usr/local/sbin/cf-vpn-firewall
BIN=/usr/local/bin/cf-vpn
XRAY_PORT=10085
APT=(apt-get -y -qq -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

if [[ -t 1 ]]; then G=$'\e[32m' R=$'\e[31m' Y=$'\e[33m' B=$'\e[1m' D=$'\e[2m' N=$'\e[0m'
else G='' R='' Y='' B='' D='' N=''; fi
info() { echo "${G}==>${N} $*"; }
warn() { echo "${Y}[!]${N} $*" >&2; }
die()  { echo "${R}[x]${N} $*" >&2; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "Нужны права root."; }
installed() { [[ -f $STATE && -f $XRAY_CONF ]]; }
# shellcheck disable=SC1090
load()      { installed || die "Ещё не установлено: cf-vpn install --domain <домен>"; source "$STATE"; }

apt_retry() {
  local i
  for i in 1 2 3 4 5; do
    "${APT[@]}" "$@" </dev/null >/dev/null && return 0
    warn "apt-get $1: попытка $i не удалась, повтор через $(( i * 10 )) с…"
    sleep $(( i * 10 )); "${APT[@]}" update </dev/null >/dev/null 2>&1 || true
  done
  die "apt-get $* не выполнился за 5 попыток."
}

usage() {
  cat <<EOF
${B}cf-vpn${N} — VLESS + XHTTP через Cloudflare

  cf-vpn install --domain D [N] [--names a,b]  установка, N клиентов (по умолчанию 3)
  cf-vpn add <имя> [имя...]                   добавить клиентов
  cf-vpn remove <имя>                         удалить клиента
  cf-vpn list                                 список клиентов
  cf-vpn qr [имя]                             ссылки и QR-коды
  cf-vpn cert                                 (пере)выпустить сертификат Let's Encrypt
  cf-vpn status                               состояние
  cf-vpn uninstall                            удалить

Клиенты: $CLIENTS_DIR  (ссылка .txt и QR .png). Приложения: Happ, Hiddify, v2rayNG, v2RayTun.
EOF
}

# ---------------------------------------------------------------- установка

install_packages() {
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
  info "Устанавливаю пакеты…"
  apt_retry update
  apt_retry install nginx certbot jq qrencode curl openssl iptables unzip
  if ! command -v xray >/dev/null; then
    info "Устанавливаю Xray (официальный скрипт XTLS)…"
    local i
    for i in 1 2 3; do
      bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1 && break
      [[ $i == 3 ]] && die "Не удалось установить Xray (GitHub недоступен?)"
      sleep 10
    done
  fi
}

write_decoy() {
  mkdir -p "$WEBROOT/.well-known/acme-challenge"
  cat >"$WEBROOT/index.html" <<'EOF'
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Notes Cloud — sign in</title>
<style>
body{margin:0;min-height:100vh;display:grid;place-items:center;background:#f4f5f7;font-family:system-ui,-apple-system,Segoe UI,sans-serif;color:#1f2328}
.card{background:#fff;padding:32px 28px;border-radius:14px;box-shadow:0 6px 24px rgba(0,0,0,.08);width:min(340px,90vw)}
h1{font-size:20px;margin:0 0 4px}p{color:#6b7280;margin:0 0 20px;font-size:14px}
input{width:100%;box-sizing:border-box;padding:10px 12px;margin:0 0 12px;border:1px solid #d0d7de;border-radius:8px;font-size:15px}
button{width:100%;padding:10px;border:0;border-radius:8px;background:#2563eb;color:#fff;font-size:15px;cursor:pointer}
small{display:block;text-align:center;margin-top:14px;color:#9ca3af}
</style></head><body>
<form class="card" onsubmit="document.getElementById('e').textContent='Invalid email or password';return false">
<h1>Notes Cloud</h1><p>Sign in to sync your notes</p>
<input type="email" placeholder="Email" required><input type="password" placeholder="Password" required>
<button>Sign in</button><small id="e">&nbsp;</small></form></body></html>
EOF
}

write_nginx() {
  local cert=$1 key=$2
  cat >"$NGINX_SITE" <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    root $WEBROOT;
    location /.well-known/acme-challenge/ { try_files \$uri =404; }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 443 ssl http2 default_server;
    listen [::]:443 ssl http2 default_server;
    server_name _;
    ssl_certificate     $cert;
    ssl_certificate_key $key;
    ssl_protocols TLSv1.2 TLSv1.3;
    root $WEBROOT;
    index index.html;
    server_tokens off;

    location $XPATH {
        client_max_body_size 0;
        client_body_timeout 5m;
        grpc_read_timeout 315s;
        grpc_send_timeout 5m;
        grpc_set_header X-Real-IP \$remote_addr;
        grpc_pass grpc://127.0.0.1:$XRAY_PORT;
    }
    location / { try_files \$uri \$uri/ /index.html; }
}
EOF
  ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/cf-vpn
  rm -f /etc/nginx/sites-enabled/default
  nginx -t >/dev/null 2>&1 || { nginx -t; die "Ошибка в конфиге nginx"; }
  systemctl reload nginx 2>/dev/null || systemctl restart nginx
}

self_signed() {
  mkdir -p /etc/ssl/cf-vpn
  [[ -f /etc/ssl/cf-vpn/cert.pem ]] && return 0
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
    -subj "/CN=$DOMAIN" -addext "subjectAltName=DNS:$DOMAIN" \
    -keyout /etc/ssl/cf-vpn/key.pem -out /etc/ssl/cf-vpn/cert.pem >/dev/null 2>&1
}

issue_cert() {
  # HTTP-01 через Cloudflare: запрос Let's Encrypt приходит на порт 80 через прокси.
  if certbot certonly --webroot -w "$WEBROOT" -d "$DOMAIN" --non-interactive --agree-tos \
       --register-unsafely-without-email --keep-until-expiring \
       --deploy-hook "systemctl reload nginx" >/dev/null 2>&1; then
    write_nginx "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "/etc/letsencrypt/live/$DOMAIN/privkey.pem"
    info "Сертификат Let's Encrypt для $DOMAIN установлен (продлевается автоматически)."
    return 0
  fi
  return 1
}

write_firewall() {
  # 80/443 принимаем только от Cloudflare: напрямую сервер не отвечает, и сканеры
  # не могут связать IP сервера с доменом. Списки IP берутся с cloudflare.com.
  cat >"$FW_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
v4=$(curl -fsS -m 15 https://www.cloudflare.com/ips-v4) || exit 0
v6=$(curl -fsS -m 15 https://www.cloudflare.com/ips-v6) || v6=""
for t in iptables ip6tables; do
  $t -N CF_ONLY 2>/dev/null || $t -F CF_ONLY
  $t -C INPUT -p tcp -m multiport --dports 80,443 -j CF_ONLY 2>/dev/null ||
    $t -I INPUT -p tcp -m multiport --dports 80,443 -j CF_ONLY
done
for n in $v4; do iptables -A CF_ONLY -s "$n" -j ACCEPT; done
for n in $v6; do ip6tables -A CF_ONLY -s "$n" -j ACCEPT; done
iptables -A CF_ONLY -s 127.0.0.0/8 -j ACCEPT
ip6tables -A CF_ONLY -s ::1 -j ACCEPT
iptables -A CF_ONLY -j DROP
ip6tables -A CF_ONLY -j DROP
EOF
  chmod 755 "$FW_SCRIPT"
  cat >/etc/systemd/system/cf-vpn-firewall.service <<EOF
[Unit]
Description=Allow HTTP(S) only from Cloudflare
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=$FW_SCRIPT
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
  cat >/etc/systemd/system/cf-vpn-firewall.timer <<EOF
[Unit]
Description=Refresh Cloudflare IP list weekly
[Timer]
OnCalendar=weekly
Persistent=true
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now cf-vpn-firewall.service cf-vpn-firewall.timer >/dev/null 2>&1
}

write_xray() {
  jq -n --arg path "$XPATH" --argjson port "$XRAY_PORT" '{
    log: {loglevel: "error", access: "none"},
    inbounds: [{
      tag: "cf-xhttp", listen: "127.0.0.1", port: $port, protocol: "vless",
      settings: {clients: [], decryption: "none"},
      streamSettings: {network: "xhttp", xhttpSettings: {path: $path, mode: "auto"}},
      sniffing: {enabled: true, destOverride: ["http", "tls", "quic"]}
    }],
    outbounds: [{protocol: "freedom", tag: "direct"}, {protocol: "blackhole", tag: "block"}],
    routing: {rules: [
      # QUIC (UDP 443) через CDN работает плохо: Instagram/YouTube подвисают,
      # не переключаясь на TCP. Блокируем — приложения сразу уходят на TCP.
      {type: "field", network: "udp", port: "443", outboundTag: "block"},
      {type: "field", protocol: ["bittorrent"], outboundTag: "block"}
    ]}
  }' >"$XRAY_CONF"
}

cmd_install() {
  local count=3 domain="" names=()
  while [[ $# -gt 0 ]]; do
    case $1 in
      -d|--domain) domain=$2; shift 2 ;;
      --names) IFS=, read -ra names <<<"$2"; shift 2 ;;
      [0-9]*) count=$1; shift ;;
      *) die "Неизвестный параметр: $1" ;;
    esac
  done
  need_root
  if installed; then warn "Уже установлено."; install_self; cmd_list; return 0; fi
  [[ -n $domain ]] || die "Укажите домен: --domain example.com"
  [[ $domain =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die "Неверный домен: $domain"
  if (( ${#names[@]} == 0 )); then local i; for i in $(seq "$count"); do names+=("client$i"); done; fi

  DOMAIN=$domain
  XPATH="/$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  install_packages
  write_decoy
  write_xray
  cat >"$STATE" <<EOF
DOMAIN='$DOMAIN'
XPATH='$XPATH'
EOF
  chmod 600 "$STATE"

  self_signed
  write_nginx /etc/ssl/cf-vpn/cert.pem /etc/ssl/cf-vpn/key.pem
  systemctl enable nginx >/dev/null 2>&1
  if issue_cert; then :; else
    warn "Let's Encrypt пока не выдал сертификат (домен ещё не активен в Cloudflare?)."
    warn "Работает временный самоподписанный — этого достаточно при SSL-режиме Full."
    warn "Когда домен активируется, выполните: cf-vpn cert"
  fi
  write_firewall

  info "Создаю клиентов: ${names[*]}"
  local n; for n in "${names[@]}"; do add_client "$n"; done
  restart_xray
  install_self
  echo
  for n in "${names[@]}"; do show_client "$n"; done
  summary
}

restart_xray() {
  xray run -test -c "$XRAY_CONF" >/dev/null 2>&1 || { xray run -test -c "$XRAY_CONF"; die "Ошибка в конфиге Xray"; }
  systemctl enable xray >/dev/null 2>&1
  systemctl restart xray
}

install_self() {
  local src=${BASH_SOURCE[0]:-}
  if [[ -n $src && -f $src && $src != /dev/* && $src != /proc/* && $src != "$BIN" ]]; then
    install -m 755 "$src" "$BIN"
  elif [[ $src != "$BIN" ]]; then
    curl -fsSL "$REPO_RAW" -o "$BIN.tmp" && chmod 755 "$BIN.tmp" && mv "$BIN.tmp" "$BIN" ||
      warn "Не удалось скачать $REPO_RAW — команда cf-vpn недоступна"
  fi
}

summary() {
  cat <<EOF
${G}${B}Готово!${N}  Домен ${B}$DOMAIN${N}, клиенты в ${B}$CLIENTS_DIR${N}

${B}Телефон:${N} приложение Happ, Hiddify или v2RayTun (iOS/Android) → «+» → сканировать QR.
${B}ПК:${N} Hiddify или v2rayN → добавить из буфера обмена ссылку vless://…
   Скачать все ссылки и QR:  scp -r root@<IP сервера>:$CLIENTS_DIR .

Управление: cf-vpn list | add <имя> | remove <имя> | qr <имя> | help
EOF
}

# ---------------------------------------------------------------- клиенты

link_for() {
  local name=$1 uuid=$2 path
  path=$(jq -rn --arg p "$XPATH" '$p|@uri')
  echo "vless://$uuid@$DOMAIN:443?encryption=none&security=tls&sni=$DOMAIN&fp=chrome&alpn=h2%2Chttp%2F1.1&type=xhttp&host=$DOMAIN&path=$path&mode=auto#$name-cf"
}

add_client() {
  local name=$1 uuid tmp
  [[ $name =~ ^[A-Za-z0-9_-]{1,32}$ ]] || die "Имя «$name»: латиница, цифры, - и _"
  jq -e --arg n "$name" '.inbounds[0].settings.clients[] | select(.email == $n)' "$XRAY_CONF" >/dev/null &&
    die "Клиент $name уже существует"
  uuid=$(xray uuid)
  tmp=$(mktemp)
  jq --arg n "$name" --arg id "$uuid" '.inbounds[0].settings.clients += [{id: $id, email: $n}]' "$XRAY_CONF" >"$tmp"
  cat "$tmp" >"$XRAY_CONF"; rm -f "$tmp"
  mkdir -p "$CLIENTS_DIR"; chmod 700 "$CLIENTS_DIR"
  ( umask 077
    link_for "$name" "$uuid" >"$CLIENTS_DIR/$name.txt"
    qrencode -t png -s 8 -m 2 -o "$CLIENTS_DIR/$name.png" <"$CLIENTS_DIR/$name.txt" )
  echo "   + $name"
}

show_client() {
  local f="$CLIENTS_DIR/$1.txt"
  [[ -f $f ]] || die "Нет клиента $1"
  echo "${B}── $1 ──${N}"
  qrencode -t ansiutf8 -m 2 <"$f"
  echo "${D}$(cat "$f")${N}"
  echo
}

cmd_add() {
  need_root; load
  [[ $# -gt 0 ]] || die "Укажите имя: cf-vpn add <имя>"
  local n; for n in "$@"; do add_client "$n"; done
  restart_xray
  for n in "$@"; do show_client "$n"; done
}

cmd_remove() {
  need_root; load
  [[ $# -gt 0 ]] || die "Укажите имя: cf-vpn remove <имя>"
  local n tmp
  for n in "$@"; do
    jq -e --arg n "$n" '.inbounds[0].settings.clients[] | select(.email == $n)' "$XRAY_CONF" >/dev/null || die "Нет клиента $n"
    tmp=$(mktemp)
    jq --arg n "$n" '.inbounds[0].settings.clients |= map(select(.email != $n))' "$XRAY_CONF" >"$tmp"
    cat "$tmp" >"$XRAY_CONF"; rm -f "$tmp"
    rm -f "$CLIENTS_DIR/$n.txt" "$CLIENTS_DIR/$n.png"
    echo "   - $n"
  done
  restart_xray
}

cmd_list() {
  load
  echo "${B}Домен:${N} $DOMAIN"
  jq -r '.inbounds[0].settings.clients[].email' "$XRAY_CONF" | sed 's/^/  /'
}

cmd_qr() {
  load
  if [[ $# -eq 0 ]]; then
    local n; for n in $(jq -r '.inbounds[0].settings.clients[].email' "$XRAY_CONF"); do show_client "$n"; done
  else
    local n; for n in "$@"; do show_client "$n"; done
  fi
}

cmd_cert() {
  need_root; load
  issue_cert || die "Let's Encrypt не выдал сертификат. Проверьте, что домен активен в Cloudflare и A-запись указывает на этот сервер (Proxied)."
}

cmd_status() {
  load
  local s
  for s in xray nginx cf-vpn-firewall; do
    systemctl is-active --quiet "$s" && echo "${G}●${N} $s" || echo "${R}●${N} $s"
  done
  if [[ -d /etc/letsencrypt/live/$DOMAIN ]]; then echo "Сертификат: Let's Encrypt"; else echo "Сертификат: самоподписанный (cf-vpn cert)"; fi
  local code
  code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "https://$DOMAIN/" || true)
  echo "https://$DOMAIN/ через Cloudflare: HTTP $code"
}

cmd_uninstall() {
  need_root; installed || die "Не установлено"
  local ans=""
  read -rp "Удалить Xray, nginx-сайт и всех клиентов? Введите yes: " ans </dev/tty || true
  [[ $ans == yes ]] || die "Отменено"
  systemctl disable --now xray cf-vpn-firewall.service cf-vpn-firewall.timer >/dev/null 2>&1 || true
  iptables -D INPUT -p tcp -m multiport --dports 80,443 -j CF_ONLY 2>/dev/null || true
  ip6tables -D INPUT -p tcp -m multiport --dports 80,443 -j CF_ONLY 2>/dev/null || true
  rm -f /etc/systemd/system/cf-vpn-firewall.* "$FW_SCRIPT" "$NGINX_SITE" /etc/nginx/sites-enabled/cf-vpn "$STATE" "$XRAY_CONF" "$BIN"
  rm -rf "$CLIENTS_DIR" "$WEBROOT"
  systemctl reload nginx 2>/dev/null || true
  echo "Удалено. Пакеты nginx/xray оставлены."
}

main() {
  local cmd=${1:-help}
  [[ $# -gt 0 ]] && shift
  case $cmd in
    help|-h|--help) usage ;;
    install)   cmd_install "$@" ;;
    add)       cmd_add "$@" ;;
    remove|rm) cmd_remove "$@" ;;
    list|ls)   cmd_list ;;
    qr|links)  cmd_qr "$@" ;;
    cert)      cmd_cert ;;
    status)    cmd_status ;;
    uninstall) cmd_uninstall ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
