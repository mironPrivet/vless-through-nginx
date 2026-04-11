#!/bin/bash
set -e

echo "=== Vless-through-Nginx Installer ==="

echo "ВНИМАНИЕ: Этот скрипт установит Nginx в вашу систему, а если он уже был установлен — перезапишет конфигурации!"
read -p "Вы уверены, что хотите продолжить? (y/n): " CONFIRM
if [[ "$CONFIRM" != "y" ]]; then
  echo "Отменено."
  exit 1
fi

# ======================
# INPUT
# ======================

read -p "Для какой страны делаем конфиг? (латиница): " COUNTRY
read -p "Введите Secret key для ноды из панели Remnawave: " REMNAKEY

read -p "Email для SSL: " EMAIL

echo ""
echo "Домены можно пропустить, нажав Enter — соответствующие инбаунды не будут созданы."
echo ""

read -p "TCP Reality domain (Enter — пропустить): "   TCP_REALITY
read -p "gRPC Reality domain (Enter — пропустить): "  GRPC_REALITY
read -p "XHTTP Reality domain (Enter — пропустить): " XHTTP_REALITY

read -p "TCP TLS domain (Enter — пропустить): "   TCP_TLS
read -p "gRPC TLS domain (Enter — пропустить): "  GRPC_TLS
read -p "XHTTP TLS domain (Enter — пропустить): " XHTTP_TLS

# Хоть что-то должно быть введено
if [[ -z "$TCP_REALITY$GRPC_REALITY$XHTTP_REALITY$TCP_TLS$GRPC_TLS$XHTTP_TLS" ]]; then
  echo "Ошибка: не введён ни один домен. Выход."
  exit 1
fi

# ======================
# SYSTEM
# ======================

apt update && apt upgrade -y
apt install -y nginx-full certbot curl openssl jq

systemctl stop nginx || true

# Приоритет IPv4 над IPv6 (решает зависание certbot на серверах со сломанным IPv6)
if ! grep -q "precedence ::ffff:0:0/96 100" /etc/gai.conf; then
  echo "precedence ::ffff:0:0/96 100" >> /etc/gai.conf
fi

if ! command -v docker &> /dev/null; then
  curl -fsSL https://get.docker.com | sh
fi

mkdir -p /opt/remnanode

cat > /opt/remnanode/docker-compose.yml <<EOF
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    volumes:
      - /dev/shm:/dev/shm:ro
      - /etc/letsencrypt/live:/etc/letsencrypt/live:ro
      - /etc/letsencrypt/archive:/etc/letsencrypt/archive:ro
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      - NODE_PORT=2222
      - SECRET_KEY=${REMNAKEY}
EOF

if ! docker ps --format '{{.Names}}' | grep -q '^remnanode$'; then
  cd /opt/remnanode && docker compose up -d
fi

echo "Ждём запуска remnanode..."
until docker exec remnanode xray version > /dev/null 2>&1; do
  sleep 2
done
echo "Remnanode готова."

# ======================
# CERTS (только для введённых доменов)
# ======================

cert () {
  [ -n "$1" ] && certbot certonly --standalone -d "$1" \
    --non-interactive --agree-tos -m "$EMAIL"
}

cert "$TCP_TLS"
cert "$GRPC_TLS"
cert "$XHTTP_TLS"

# Reality домены — сертификаты нужны для selfsteal в nginx
cert "$TCP_REALITY"
cert "$GRPC_REALITY"
cert "$XHTTP_REALITY"

# ======================
# GENERATORS
# ======================

mlkem_seed () {
  docker exec remnanode xray mlkem768 mlkem768 | grep Seed: | awk '{print $2}'
}

x25519_priv () {
  docker exec remnanode xray x25519 | grep PrivateKey: | awk '{print $2}'
}

sid () {
  openssl rand -hex 8
}

# ======================
# TLS SEEDS (только для введённых доменов)
# ======================

[ -n "$TCP_TLS" ]   && TCP_TLS_SEED=$(mlkem_seed)
[ -n "$GRPC_TLS" ]  && GRPC_TLS_SEED=$(mlkem_seed)
[ -n "$XHTTP_TLS" ] && XHTTP_TLS_SEED=$(mlkem_seed)

# ======================
# REALITY KEYS (только для введённых доменов)
# ======================

if [ -n "$TCP_REALITY" ]; then
  TCP_PRIV=$(x25519_priv)
  TCP_SID=$(sid)
fi

if [ -n "$GRPC_REALITY" ]; then
  GRPC_PRIV=$(x25519_priv)
  GRPC_SID=$(sid)
fi

if [ -n "$XHTTP_REALITY" ]; then
  XHTTP_PRIV=$(x25519_priv)
  XHTTP_SID=$(sid)
fi

# ======================
# NGINX
# ======================

cat > /etc/nginx/nginx.conf <<'NGINXEOF'
user www-data;
worker_processes auto;
load_module modules/ngx_stream_module.so;

events { worker_connections 1024; }

stream {

NGINXEOF

# Upstream блоки — только для введённых доменов
[ -n "$TCP_TLS" ]       && echo "    upstream tcp_tls       { server 127.0.0.1:5556; }" >> /etc/nginx/nginx.conf
[ -n "$GRPC_TLS" ]      && echo "    upstream grpc_tls      { server 127.0.0.1:5555; }" >> /etc/nginx/nginx.conf
[ -n "$XHTTP_TLS" ]     && echo "    upstream xhttp_tls     { server 127.0.0.1:5557; }" >> /etc/nginx/nginx.conf
[ -n "$TCP_REALITY" ]   && echo "    upstream tcp_reality   { server 127.0.0.1:5558; }" >> /etc/nginx/nginx.conf
[ -n "$GRPC_REALITY" ]  && echo "    upstream grpc_reality  { server 127.0.0.1:5559; }" >> /etc/nginx/nginx.conf
[ -n "$XHTTP_REALITY" ] && echo "    upstream xhttp_reality { server 127.0.0.1:5560; }" >> /etc/nginx/nginx.conf

cat >> /etc/nginx/nginx.conf <<'NGINXEOF'

    map $ssl_preread_server_name $backend {
        hostnames;

NGINXEOF

# Map записи — только для введённых доменов
[ -n "$TCP_TLS" ]       && echo "        ${TCP_TLS}       tcp_tls;"       >> /etc/nginx/nginx.conf
[ -n "$GRPC_TLS" ]      && echo "        ${GRPC_TLS}      grpc_tls;"      >> /etc/nginx/nginx.conf
[ -n "$XHTTP_TLS" ]     && echo "        ${XHTTP_TLS}     xhttp_tls;"     >> /etc/nginx/nginx.conf
[ -n "$TCP_REALITY" ]   && echo "        ${TCP_REALITY}   tcp_reality;"   >> /etc/nginx/nginx.conf
[ -n "$GRPC_REALITY" ]  && echo "        ${GRPC_REALITY}  grpc_reality;"  >> /etc/nginx/nginx.conf
[ -n "$XHTTP_REALITY" ] && echo "        ${XHTTP_REALITY} xhttp_reality;" >> /etc/nginx/nginx.conf

cat >> /etc/nginx/nginx.conf <<'NGINXEOF'
    }

    server {
        listen 443;
        ssl_preread on;
        proxy_pass $backend;
        proxy_protocol on;
    }
}

http {

NGINXEOF

# HTTP selfsteal блоки — только для введённых Reality доменов
add_http () {
  local DOM=$1
  local PORT=$2
  [ -z "$DOM" ] && return
  cat >> /etc/nginx/nginx.conf <<EOF
    server {
        listen 127.0.0.1:${PORT} ssl;
        server_name ${DOM};

        set_real_ip_from 127.0.0.1;
        real_ip_header proxy_protocol;

        ssl_certificate     /etc/letsencrypt/live/${DOM}/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/${DOM}/privkey.pem;

        location / {
            root /var/www/html;
        }
    }

EOF
}

add_http "$TCP_REALITY"   6000
add_http "$GRPC_REALITY"  6001
add_http "$XHTTP_REALITY" 6002

echo "}" >> /etc/nginx/nginx.conf

nginx -t
systemctl restart nginx

# ======================
# XRAY CONFIG
# ======================

INBOUNDS=""

add_inbound () {
  if [ -n "$INBOUNDS" ]; then
    INBOUNDS="${INBOUNDS},"
  fi
  INBOUNDS="${INBOUNDS}
$1"
}

# Autoselect и ShadowSocks — всегда
add_inbound '{
      "tag": "'"${COUNTRY} Autoselect"'",
      "port": 9997,
      "listen": "0.0.0.0",
      "protocol": "shadowsocks",
      "settings": { "clients": [], "network": "tcp,udp" },
      "sniffing": { "enabled": false, "destOverride": ["http","tls","quic"] }
    }'

add_inbound '{
      "tag": "'"${COUNTRY} ShadowSocks"'",
      "port": 9998,
      "listen": "0.0.0.0",
      "protocol": "shadowsocks",
      "settings": { "clients": [], "network": "tcp,udp" },
      "sniffing": { "enabled": false, "destOverride": ["http","tls","quic"] }
    }'

# TCP TLS
if [ -n "$TCP_TLS" ]; then
add_inbound '{
      "tag": "'"${COUNTRY} TCP TLS with vlessEncrypted"'",
      "port": 5556,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": { "clients": [], "decryption": "mlkem768x25519plus.xorpub.600s.'"${TCP_TLS_SEED}"'" },
      "sniffing": { "enabled": false, "destOverride": ["http","tls","quic"] },
      "streamSettings": {
        "network": "tcp",
        "sockopt": { "acceptProxyProtocol": true },
        "security": "tls",
        "tlsSettings": {
          "serverName": "'"${TCP_TLS}"'",
          "certificates": [{ "keyFile": "/etc/letsencrypt/live/'"${TCP_TLS}"'/privkey.pem", "certificateFile": "/etc/letsencrypt/live/'"${TCP_TLS}"'/fullchain.pem" }]
        }
      }
    }'
fi

# gRPC TLS
if [ -n "$GRPC_TLS" ]; then
add_inbound '{
      "tag": "'"${COUNTRY} gRPC TLS with vlessEncrypted"'",
      "port": 5555,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": { "clients": [], "decryption": "mlkem768x25519plus.xorpub.600s.'"${GRPC_TLS_SEED}"'" },
      "sniffing": { "enabled": false, "destOverride": ["http","tls","quic"] },
      "streamSettings": {
        "network": "grpc",
        "sockopt": { "acceptProxyProtocol": true },
        "security": "tls",
        "tlsSettings": {
          "serverName": "'"${GRPC_TLS}"'",
          "certificates": [{ "keyFile": "/etc/letsencrypt/live/'"${GRPC_TLS}"'/privkey.pem", "certificateFile": "/etc/letsencrypt/live/'"${GRPC_TLS}"'/fullchain.pem" }]
        },
        "grpcSettings": { "serviceName": "grpc" }
      }
    }'
fi

# XHTTP TLS
if [ -n "$XHTTP_TLS" ]; then
add_inbound '{
      "tag": "'"${COUNTRY} XHTTP TLS with vlessEncrypted"'",
      "port": 5557,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": { "clients": [], "decryption": "mlkem768x25519plus.xorpub.600s.'"${XHTTP_TLS_SEED}"'" },
      "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"] },
      "streamSettings": {
        "network": "xhttp",
        "sockopt": { "acceptProxyProtocol": true },
        "security": "tls",
        "tlsSettings": {
          "serverName": "'"${XHTTP_TLS}"'",
          "certificates": [{ "keyFile": "/etc/letsencrypt/live/'"${XHTTP_TLS}"'/privkey.pem", "certificateFile": "/etc/letsencrypt/live/'"${XHTTP_TLS}"'/fullchain.pem" }]
        },
        "xhttpSettings": {
          "host": "'"${XHTTP_TLS}"'",
          "mode": "stream-up",
          "path": "/xhttp",
          "extra": { "xmux": { "cMaxReuseTimes": 0, "maxConcurrency": "1", "maxConnections": 0, "hKeepAlivePeriod": 0, "hMaxRequestTimes": "600-900", "hMaxReusableSecs": "1800-3000" } }
        }
      }
    }'
fi

# TCP Reality
if [ -n "$TCP_REALITY" ]; then
add_inbound '{
      "tag": "'"${COUNTRY} TCP Reality"'",
      "port": 5558,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": { "clients": [], "decryption": "none" },
      "sniffing": { "enabled": false, "destOverride": ["http","tls","quic"] },
      "streamSettings": {
        "network": "raw",
        "sockopt": { "acceptProxyProtocol": true },
        "security": "reality",
        "realitySettings": {
          "show": false, "xver": 1, "target": "6000", "spiderX": "",
          "serverNames": ["'"${TCP_REALITY}"'"],
          "privateKey": "'"${TCP_PRIV}"'",
          "shortIds": ["'"${TCP_SID}"'"]
        }
      }
    }'
fi

# gRPC Reality
if [ -n "$GRPC_REALITY" ]; then
add_inbound '{
      "tag": "'"${COUNTRY} gRPC Reality"'",
      "port": 5559,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": { "clients": [], "decryption": "none" },
      "sniffing": { "enabled": false, "destOverride": ["http","tls","quic"] },
      "streamSettings": {
        "network": "grpc",
        "sockopt": { "acceptProxyProtocol": true },
        "security": "reality",
        "realitySettings": {
          "show": false, "xver": 1, "target": "6001", "spiderX": "",
          "serverNames": ["'"${GRPC_REALITY}"'"],
          "privateKey": "'"${GRPC_PRIV}"'",
          "shortIds": ["'"${GRPC_SID}"'"]
        },
        "grpcSettings": { "serviceName": "grpc" }
      }
    }'
fi

# XHTTP Reality
if [ -n "$XHTTP_REALITY" ]; then
add_inbound '{
      "tag": "'"${COUNTRY} XHTTP Reality"'",
      "port": 5560,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": { "clients": [], "decryption": "none" },
      "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"] },
      "streamSettings": {
        "network": "xhttp",
        "sockopt": { "acceptProxyProtocol": true },
        "security": "reality",
        "xhttpSettings": {
          "mode": "stream-up",
          "path": "/xhttp",
          "extra": {
            "xmux": { "cMaxReuseTimes": 0, "maxConcurrency": "1", "maxConnections": 0, "hKeepAlivePeriod": 0, "hMaxRequestTimes": "600-900", "hMaxReusableSecs": "1800-2500" },
            "headers": {}, "security": "reality", "noSSEHeader": false, "noGRPCHeader": false, "xPaddingBytes": "100-1000"
          }
        },
        "realitySettings": {
          "show": false, "xver": 1, "target": "6002", "spiderX": "",
          "serverNames": ["'"${XHTTP_REALITY}"'"],
          "privateKey": "'"${XHTTP_PRIV}"'",
          "shortIds": ["'"${XHTTP_SID}"'"]
        }
      }
    }'
fi

# Записываем финальный JSON
cat > /root/xray.json <<EOF
{
  "log": { "loglevel": "info" },
  "inbounds": [${INBOUNDS}
  ],
  "outbounds": [
    { "tag": "DIRECT", "protocol": "freedom" },
    { "tag": "BLOCK",  "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "domain": ["geosite:category-ru"], "outboundTag": "BLOCK" },
      { "type": "field", "protocol": ["bittorrent"], "outboundTag": "BLOCK" }
    ]
  }
}
EOF

echo ""
echo "=============================="
echo "DONE"
echo "Country:      $COUNTRY"
echo "Config saved: /root/xray.json"
echo ""

# ======================
# UPLOAD CONFIG
# ======================

echo "--- Загружаем конфиг онлайн... ---"

PASTE_URL=""

IX_RESPONSE=$(curl -s -F 'f:1=</root/xray.json' http://ix.io 2>/dev/null || true)
if echo "$IX_RESPONSE" | grep -qE '^http'; then
  PASTE_URL="$IX_RESPONSE"
  echo "Загружено на ix.io: $PASTE_URL"
fi

if [ -z "$PASTE_URL" ]; then
  PRS_RESPONSE=$(curl -s --data-binary @/root/xray.json https://paste.rs 2>/dev/null || true)
  if echo "$PRS_RESPONSE" | grep -qE '^https://paste\.rs/'; then
    PASTE_URL="$PRS_RESPONSE"
    echo "Загружено на paste.rs: $PASTE_URL"
  fi
fi

if [ -z "$PASTE_URL" ]; then
  echo "Не удалось загрузить онлайн. Конфиг доступен локально: /root/xray.json"
fi

echo ""
echo "--- Reality Keys ---"
if [ -n "$TCP_REALITY" ]; then
  echo "TCP   shortId: ${TCP_SID}"
fi
if [ -n "$GRPC_REALITY" ]; then
  echo "gRPC  shortId: ${GRPC_SID}"
fi
if [ -n "$XHTTP_REALITY" ]; then
  echo "XHTTP shortId: ${XHTTP_SID}"
fi
echo "=============================="
