#!/usr/bin/env bash
# AmneziaWG VPN: установка одной командой и управление клиентами.
# https://github.com/Rodion4365/amnezia-vpn-installer
#
# Установка на чистом Ubuntu 22.04 / 24.04 (от root):
#   curl -fsSL https://raw.githubusercontent.com/Rodion4365/amnezia-vpn-installer/main/awg-vpn.sh | bash
#
# Весь код обёрнут в функции, а запуск — в последней строке, чтобы при
# `curl | bash` скрипт был прочитан целиком до начала выполнения.

set -Eeuo pipefail
export LC_ALL=C.UTF-8

REPO_RAW="https://raw.githubusercontent.com/Rodion4365/amnezia-vpn-installer/main/awg-vpn.sh"
IFACE="${AWG_IFACE:-awg0}"
CONF_DIR=/etc/amnezia/amneziawg
CONF="$CONF_DIR/$IFACE.conf"
PARAMS="$CONF_DIR/$IFACE.params"
CLIENTS_DIR="${AWG_CLIENTS_DIR:-/root/awg-clients}"
BIN=/usr/local/bin/awg-vpn
SYSCTL_FILE=/etc/sysctl.d/99-awg-vpn.conf
APT=(apt-get -y -qq -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

if [[ -t 1 ]]; then
  G=$'\e[32m' R=$'\e[31m' Y=$'\e[33m' B=$'\e[1m' D=$'\e[2m' N=$'\e[0m'
else
  G='' R='' Y='' B='' D='' N=''
fi
info() { echo "${G}==>${N} $*"; }
warn() { echo "${Y}[!]${N} $*" >&2; }
die()  { echo "${R}[x]${N} $*" >&2; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "Нужны права root. Зайдите как root или запустите через sudo."; }
installed() { [[ -f $CONF && -f $PARAMS ]]; }
# shellcheck disable=SC1090
load()      { installed || die "VPN ещё не установлен. Установка: awg-vpn install"; source "$PARAMS"; }
rand()      { shuf -i "$1-$2" -n 1; }

# apt с повторами: репозитории (особенно Launchpad) иногда отвечают 503.
apt_retry() {
  local i
  for i in 1 2 3 4 5; do
    "${APT[@]}" "$@" </dev/null >/dev/null && return 0
    warn "apt-get $1: попытка $i не удалась, повтор через $(( i * 10 )) с…"
    sleep $(( i * 10 ))
    "${APT[@]}" update </dev/null >/dev/null 2>&1 || true
  done
  die "apt-get $* не выполнился за 5 попыток. Проверьте интернет на сервере и запустите установку ещё раз."
}
reload()    { awg syncconf "$IFACE" <(awg-quick strip "$IFACE"); }

usage() {
  cat <<EOF
${B}awg-vpn${N} — AmneziaWG VPN-сервер

  awg-vpn install [N] [опции]   установить сервер и создать N клиентов (по умолчанию 3)
      --port P                  UDP-порт (по умолчанию случайный 30000–60000)
      --endpoint IP             внешний IP/домен сервера (по умолчанию определяется сам)
      --names a,b,c             имена клиентов вместо client1..N
      --dns "1.1.1.1, 8.8.8.8"  DNS для клиентов
      --subnet 10.8.0           подсеть VPN (/24)
  awg-vpn add <имя> [имя...]    добавить клиентов
  awg-vpn remove <имя>          удалить клиента
  awg-vpn list                  клиенты, последнее подключение, трафик
  awg-vpn qr <имя>              показать QR-код клиента в терминале
  awg-vpn share [минут]         временная ссылка для скачивания конфигов в браузере (15 мин)
  awg-vpn status                состояние сервера
  awg-vpn uninstall             удалить VPN с сервера

Файлы клиентов: $CLIENTS_DIR  (.conf, .png с QR, vpn-configs.zip)
EOF
}

# ---------------------------------------------------------------- установка

check_os() {
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID}:${VERSION_ID}" in
    ubuntu:22.04|ubuntu:24.04) ;;
    ubuntu:20.04) warn "Ubuntu 20.04 устарела, рекомендуется 24.04. Продолжаю…" ;;
    ubuntu:*)     warn "Ubuntu $VERSION_ID не проверялась (рекомендуется 24.04). Продолжаю…" ;;
    *) die "Поддерживается Ubuntu 22.04 / 24.04. У вас: ${PRETTY_NAME:-неизвестная ОС}" ;;
  esac
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
  info "Устанавливаю пакеты (обычно 1–3 минуты)…"
  apt_retry update
  apt_retry install software-properties-common gnupg curl iptables qrencode zip python3 iproute2
  if ! "${APT[@]}" install "linux-headers-$(uname -r)" </dev/null >/dev/null 2>&1; then
    warn "Пакет linux-headers-$(uname -r) не найден — модуль ядра может не собраться."
  fi
  if ! grep -rqs "amnezia/ppa" /etc/apt/sources.list /etc/apt/sources.list.d/; then
    info "Подключаю репозиторий Amnezia (ppa:amnezia/ppa)…"
    add-apt-repository -y ppa:amnezia/ppa </dev/null >/dev/null ||
      add-apt-repository -y ppa:amnezia/ppa </dev/null >/dev/null ||
      die "Не удалось подключить ppa:amnezia/ppa (Launchpad недоступен?). Запустите установку ещё раз."
  fi
  apt_retry update
  info "Устанавливаю AmneziaWG (сборка модуля ядра занимает до минуты)…"
  apt_retry install amneziawg
}

load_module() {
  modprobe amneziawg 2>/dev/null && return 0
  dkms autoinstall >/dev/null 2>&1 || true
  modprobe amneziawg 2>/dev/null && return 0
  local hint=""
  [[ -f /var/run/reboot-required ]] && hint=" Система ждёт перезагрузки после обновления ядра."
  die "Модуль ядра amneziawg не загрузился (ядро $(uname -r)).$hint
    Обычно помогает:  apt install -y linux-generic && reboot
    После перезагрузки запустите команду установки ещё раз."
}

detect_wan() {
  ip -4 route show default | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i+1); exit }}'
}

detect_ip() {
  local ip
  ip=$(ip -4 -o addr show dev "$1" scope global | awk '{print $4}' | cut -d/ -f1 |
       grep -vE '^(10\.|127\.|169\.254\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)' |
       head -n 1 || true)
  if [[ -z $ip ]]; then
    ip=$(curl -4 -fsS -m 6 https://api.ipify.org 2>/dev/null || curl -4 -fsS -m 6 https://ifconfig.me 2>/dev/null ||
         curl -4 -fsS -m 6 https://icanhazip.com 2>/dev/null || true)
    ip=$(tr -d '[:space:]' <<<"$ip")
  fi
  echo "$ip"
}

pick_port() {
  local p
  for _ in $(seq 50); do
    p=$(rand 30000 60000)
    ss -Hlun "sport = :$p" 2>/dev/null | grep -q . || { echo "$p"; return; }
  done
  die "Не удалось подобрать свободный UDP-порт, укажите --port"
}

gen_obfuscation() {
  # Параметры обфускации AmneziaWG: мусорные пакеты (Jc/Jmin/Jmax),
  # мусор в начале handshake (S1/S2) и свои «магические» заголовки (H1–H4).
  JC=$(rand 4 10)
  JMIN=$(rand 40 80)
  JMAX=$(( JMIN + $(rand 300 700) ))
  S1=$(rand 15 150)
  S2=$(rand 15 150)
  while (( S1 + 56 == S2 )); do S2=$(rand 15 150); done
  local h=() v
  while (( ${#h[@]} < 4 )); do
    v=$(rand 5 2147483647)
    [[ " ${h[*]} " == *" $v "* ]] || h+=("$v")
  done
  H1=${h[0]} H2=${h[1]} H3=${h[2]} H4=${h[3]}
}

setup_firewall() {
  # Открываем порт в ufw, если он включён (iptables-правила добавляет PostUp).
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "$PORT/udp" >/dev/null
    ufw route allow in on "$IFACE" out on "$WAN" >/dev/null 2>&1 || true
  fi
}

cmd_install() {
  local count=3 port="" endpoint="" dns="1.1.1.1, 8.8.8.8" subnet="10.8.0" names=()
  while [[ $# -gt 0 ]]; do
    case $1 in
      -n|--clients) count=$2; shift 2 ;;
      -p|--port)    port=$2; shift 2 ;;
      -e|--endpoint) endpoint=$2; shift 2 ;;
      --dns)        dns=$2; shift 2 ;;
      --subnet)     subnet=${2%.0/24}; subnet=${subnet%.0}; shift 2 ;;
      --names)      IFS=, read -ra names <<<"$2"; shift 2 ;;
      [0-9]*)       count=$1; shift ;;
      *) die "Неизвестный параметр: $1 (см. awg-vpn help)" ;;
    esac
  done
  need_root
  if installed; then
    warn "VPN уже установлен на этом сервере."
    install_self
    cmd_list
    echo; echo "Добавить клиента: ${B}awg-vpn add <имя>${N}   Справка: ${B}awg-vpn help${N}"
    return 0
  fi
  [[ $count =~ ^[0-9]+$ ]] && (( count >= 1 && count <= 250 )) || die "Число клиентов должно быть от 1 до 250"
  [[ $subnet =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || die "Подсеть указывается так: --subnet 10.8.0"
  [[ -z $port || ( $port =~ ^[0-9]+$ && $port -ge 1 && $port -le 65535 ) ]] || die "Неверный порт: $port"
  if (( ${#names[@]} == 0 )); then
    local i; for i in $(seq "$count"); do names+=("client$i"); done
  fi

  check_os
  install_packages
  load_module

  WAN=$(detect_wan)
  [[ -n $WAN ]] || die "Не найден сетевой интерфейс с маршрутом по умолчанию"
  ENDPOINT=${endpoint:-$(detect_ip "$WAN")}
  [[ -n $ENDPOINT ]] || die "Не удалось определить внешний IP. Укажите его: --endpoint <IP>"
  PORT=${port:-$(pick_port)}
  SUBNET=$subnet DNS=$dns MTU=1280
  info "Внешний адрес: $ENDPOINT, порт UDP $PORT, интерфейс $WAN"

  gen_obfuscation
  local spriv; spriv=$(awg genkey)
  SERVER_PUB=$(awg pubkey <<<"$spriv")

  info "Настраиваю сервер…"
  mkdir -p "$CONF_DIR"; chmod 700 "$CONF_DIR"
  local up down
  up="iptables -I INPUT -p udp --dport $PORT -j ACCEPT; iptables -I FORWARD -i %i -j ACCEPT; iptables -I FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -s $SUBNET.0/24 -o $WAN -j MASQUERADE; iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu"
  down="${up//-I /-D }"; down="${down//-A /-D }"
  ( umask 077
    cat >"$CONF" <<EOF
[Interface]
Address = $SUBNET.1/24
ListenPort = $PORT
PrivateKey = $spriv
Jc = $JC
Jmin = $JMIN
Jmax = $JMAX
S1 = $S1
S2 = $S2
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4
PostUp = $up
PostDown = $down
EOF
    cat >"$PARAMS" <<EOF
ENDPOINT='$ENDPOINT'
PORT='$PORT'
WAN='$WAN'
SUBNET='$SUBNET'
DNS='$DNS'
MTU='$MTU'
SERVER_PUB='$SERVER_PUB'
EOF
  )

  cat >"$SYSCTL_FILE" <<EOF
net.ipv4.ip_forward = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  sysctl -q -p "$SYSCTL_FILE" >/dev/null 2>&1 || sysctl -q -w net.ipv4.ip_forward=1 >/dev/null
  setup_firewall

  systemctl enable --now "awg-quick@$IFACE" >/dev/null 2>&1 ||
    die "Не удалось запустить awg-quick@$IFACE: journalctl -u awg-quick@$IFACE"

  info "Создаю клиентов: ${names[*]}"
  local n
  for n in "${names[@]}"; do add_client "$n"; done
  reload
  make_zip
  install_self

  echo
  for n in "${names[@]}"; do show_qr "$n"; done
  summary
}

install_self() {
  local src=${BASH_SOURCE[0]:-}
  if [[ -n $src && -f $src && $src != /dev/* && $src != /proc/* && $src != "$BIN" ]]; then
    install -m 755 "$src" "$BIN"
  elif [[ ! -x $BIN || $src != "$BIN" ]]; then
    curl -fsSL "$REPO_RAW" -o "$BIN.tmp" && chmod 755 "$BIN.tmp" && mv "$BIN.tmp" "$BIN" ||
      warn "Не удалось скачать $REPO_RAW — команда awg-vpn недоступна"
  fi
}

summary() {
  cat <<EOF
${G}${B}VPN готов!${N}  Сервер ${B}$ENDPOINT:$PORT${N}, клиенты в ${B}$CLIENTS_DIR${N}

${B}1. Телефон:${N} установите приложение AmneziaVPN или AmneziaWG и отсканируйте QR-код выше.

${B}2. Скачать конфиги на компьютер${N} — откройте терминал на своём ПК (Windows: PowerShell) и выполните:
     scp root@$ENDPOINT:$CLIENTS_DIR/vpn-configs.zip .
   Или временная ссылка для браузера (действует 15 минут):
     awg-vpn share

${B}Управление:${N} awg-vpn list | add <имя> | remove <имя> | qr <имя> | help
EOF
}

# ---------------------------------------------------------------- клиенты

obf_lines() { grep -E '^(Jc|Jmin|Jmax|S1|S2|H1|H2|H3|H4) = ' "$CONF"; }
client_exists() { grep -qx "### client $1" "$CONF"; }

add_client() {
  local name=$1 ip="" i priv pub psk
  [[ $name =~ ^[A-Za-z0-9_-]{1,32}$ ]] || die "Имя «$name»: только латиница, цифры, - и _ (до 32 символов)"
  client_exists "$name" && die "Клиент $name уже существует"
  for i in $(seq 2 254); do
    grep -q "^AllowedIPs = $SUBNET\.$i/32\$" "$CONF" || { ip="$SUBNET.$i"; break; }
  done
  [[ -n $ip ]] || die "Свободные адреса в подсети $SUBNET.0/24 закончились"
  priv=$(awg genkey); pub=$(awg pubkey <<<"$priv"); psk=$(awg genpsk)

  ( umask 077
    cat >>"$CONF" <<EOF

### client $name
[Peer]
PublicKey = $pub
PresharedKey = $psk
AllowedIPs = $ip/32
EOF
    mkdir -p "$CLIENTS_DIR"
    cat >"$CLIENTS_DIR/$name.conf" <<EOF
[Interface]
PrivateKey = $priv
Address = $ip/32
DNS = $DNS
MTU = $MTU
$(obf_lines)

[Peer]
PublicKey = $SERVER_PUB
PresharedKey = $psk
Endpoint = $ENDPOINT:$PORT
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
    qrencode -t png -s 8 -m 2 -o "$CLIENTS_DIR/$name.png" <"$CLIENTS_DIR/$name.conf"
  )
  chmod 700 "$CLIENTS_DIR"
  echo "   + $name ($ip)"
}

make_zip() {
  rm -f "$CLIENTS_DIR/vpn-configs.zip"
  compgen -G "$CLIENTS_DIR/*.conf" >/dev/null || return 0
  ( cd "$CLIENTS_DIR" && umask 077 && zip -qj vpn-configs.zip ./*.conf ./*.png )
}

show_qr() {
  local f="$CLIENTS_DIR/$1.conf"
  [[ -f $f ]] || die "Нет клиента $1 (список: awg-vpn list)"
  echo "${B}── $1 ──${N}  ${D}$f${N}"
  qrencode -t ansiutf8 -m 2 <"$f"
  echo
}

cmd_add() {
  need_root; load
  [[ $# -gt 0 ]] || die "Укажите имя: awg-vpn add <имя> [имя...]"
  local n
  for n in "$@"; do add_client "$n"; done
  reload; make_zip
  for n in "$@"; do show_qr "$n"; done
  echo "Скачать на ПК: scp root@$ENDPOINT:$CLIENTS_DIR/vpn-configs.zip .   или   awg-vpn share"
}

cmd_remove() {
  need_root; load
  [[ $# -gt 0 ]] || die "Укажите имя: awg-vpn remove <имя>"
  local n tmp
  for n in "$@"; do
    client_exists "$n" || die "Нет клиента $n"
    tmp=$(mktemp)
    awk -v m="### client $n" '$0 == m {skip = 1; next} /^### client / {skip = 0} !skip' "$CONF" >"$tmp"
    cat "$tmp" >"$CONF"; rm -f "$tmp"
    rm -f "$CLIENTS_DIR/$n.conf" "$CLIENTS_DIR/$n.png"
    echo "   - $n"
  done
  reload; make_zip
}

# Выравнивание по символам, а не байтам (printf считает байты, кириллица съезжает).
pad() { local s=$1; printf '%s%*s' "$s" $(( $2 > ${#s} ? $2 - ${#s} : 1 )) ''; }

ago() {
  local s=$(( $(date +%s) - $1 ))
  if   (( $1 == 0 ));   then echo "никогда"
  elif (( s < 60 ));    then echo "${s} с назад"
  elif (( s < 3600 ));  then echo "$(( s / 60 )) мин назад"
  elif (( s < 86400 )); then echo "$(( s / 3600 )) ч назад"
  else                       echo "$(( s / 86400 )) дн назад"
  fi
}

cmd_list() {
  load
  local hs tr
  hs=$(awg show "$IFACE" latest-handshakes 2>/dev/null || true)
  tr=$(awg show "$IFACE" transfer 2>/dev/null || true)
  echo "${B}$(pad КЛИЕНТ 18)$(pad IP 15)$(pad ПОДКЛЮЧЕНИЕ 17)ПОЛУЧЕНО / ОТДАНО${N}"
  awk '/^### client /{name=$3} /^PublicKey = /{pub=$3} /^AllowedIPs = /{print name, pub, $3}' "$CONF" |
  while read -r name pub ip; do
    local t rx tx
    t=$(awk -v k="$pub" '$1 == k {print $2}' <<<"$hs"); t=${t:-0}
    read -r rx tx < <(awk -v k="$pub" '$1 == k {print $2, $3}' <<<"$tr"; echo "0 0")
    echo "$(pad "$name" 18)$(pad "${ip%/32}" 15)$(pad "$(ago "$t")" 17)$(numfmt --to=iec --suffix=B "${rx:-0}") / $(numfmt --to=iec --suffix=B "${tx:-0}")"
  done
}

cmd_qr() {
  load
  if [[ $# -eq 0 ]]; then
    local f; for f in "$CLIENTS_DIR"/*.conf; do [[ -f $f ]] && show_qr "$(basename "$f" .conf)"; done
  else
    local n; for n in "$@"; do show_qr "$n"; done
  fi
}

cmd_share() {
  need_root; load
  local minutes=${1:-15} token port dir
  [[ $minutes =~ ^[0-9]+$ ]] || die "Время в минутах: awg-vpn share 15"
  compgen -G "$CLIENTS_DIR/*.conf" >/dev/null || die "Нет клиентов для скачивания"
  token=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
  port=$(rand 40000 60000)
  dir=$(mktemp -d)
  mkdir "$dir/$token"
  : >"$dir/index.html"
  make_zip
  cp "$CLIENTS_DIR"/*.conf "$CLIENTS_DIR"/*.png "$CLIENTS_DIR/vpn-configs.zip" "$dir/$token/"
  {
    echo '<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
    echo '<title>VPN</title><style>body{font-family:system-ui,sans-serif;max-width:760px;margin:24px auto;padding:0 16px}'
    echo '.c{display:inline-block;margin:10px;text-align:center}img{width:260px;image-rendering:pixelated}</style>'
    echo '<h2>Конфиги VPN</h2><p><a href="vpn-configs.zip"><b>Скачать всё (zip)</b></a></p>'
    local f n
    for f in "$CLIENTS_DIR"/*.conf; do
      n=$(basename "$f" .conf)
      echo "<div class=c><img src=\"$n.png\" alt=\"$n\"><br><a href=\"$n.conf\" download>$n.conf</a></div>"
    done
  } >"$dir/$token/index.html"

  iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
  local ufw_on=0
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "$port/tcp" >/dev/null; ufw_on=1
  fi
  # shellcheck disable=SC2064
  trap "iptables -D INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null || true; if [ $ufw_on = 1 ]; then ufw delete allow $port/tcp >/dev/null || true; fi; rm -rf '$dir'" EXIT

  cat <<EOF

Откройте в браузере на компьютере или телефоне:

   ${B}http://$ENDPOINT:$port/$token/${N}

${Y}Ссылка работает $minutes мин или до Ctrl+C.${N} Соединение не шифруется (HTTP) —
не пересылайте ссылку и закройте её сразу после скачивания.
EOF
  timeout "${minutes}m" python3 -m http.server "$port" --bind 0.0.0.0 --directory "$dir" >/dev/null 2>&1 || true
  echo "Ссылка закрыта."
}

cmd_status() {
  load
  systemctl is-active --quiet "awg-quick@$IFACE" && echo "${G}●${N} VPN работает" || echo "${R}●${N} VPN остановлен"
  echo "Сервер: $ENDPOINT:$PORT  (интерфейс $IFACE, подсеть $SUBNET.0/24, выход через $WAN)"
  echo
  cmd_list
}

cmd_uninstall() {
  need_root
  installed || die "VPN не установлен"
  local ans=""
  read -rp "Удалить VPN и всех клиентов с этого сервера? Введите yes: " ans </dev/tty || true
  [[ $ans == yes ]] || die "Отменено"
  systemctl disable --now "awg-quick@$IFACE" >/dev/null 2>&1 || true
  rm -f "$CONF" "$PARAMS" "$SYSCTL_FILE" "$BIN"
  rm -rf "$CLIENTS_DIR"
  echo "VPN удалён. Пакеты AmneziaWG оставлены: apt purge amneziawg amneziawg-dkms amneziawg-tools"
}

main() {
  local cmd=${1:-install}
  [[ $# -gt 0 ]] && shift
  case $cmd in
    help|-h|--help) usage ;;
    install)        cmd_install "$@" ;;
    [0-9]*|--*)     cmd_install "$cmd" "$@" ;;
    add)            cmd_add "$@" ;;
    remove|rm|del)  cmd_remove "$@" ;;
    list|ls)        cmd_list ;;
    qr)             cmd_qr "$@" ;;
    share)          cmd_share "$@" ;;
    status)         cmd_status ;;
    uninstall)      cmd_uninstall ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
