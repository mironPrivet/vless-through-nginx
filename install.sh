#!/bin/bash
set -e

echo "=== Vless-through-Nginx Installer ==="

# ======================
# INPUT
# ======================

read -p "Для какой страны делаем конфиг? (латиница): " COUNTRY
read -p "Введите Secret key для ноды из панели Remnawave: " REMNAKEY

read -p "Email для SSL: " EMAIL

read -p "TCP Reality domain: " TCP_REALITY
read -p "gRPC Reality domain: " GRPC_REALITY
read -p "XHTTP Reality domain: " XHTTP_REALITY

read -p "TCP TLS domain: " TCP_TLS
read -p "gRPC TLS domain: " GRPC_TLS
read -p "XHTTP TLS domain: " XHTTP_TLS

# ======================
# SYSTEM
# ======================

apt update && apt upgrade -y
apt install -y nginx-full certbot curl openssl jq

systemctl stop nginx || true

curl -fsSL https://get.docker.com | sh
mkdir /opt/remnanode && cd /opt/remnanode
cat <<EOF > /opt/remnanode/docker-compose.yml
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
docker compose up -d

echo "Ждём запуска remnanode..."
until docker exec remnanode xray version > /dev/null 2>&1; do
  sleep 2
done
echo "Remnanode готова."

# ======================
# CERTS
# ======================

cert () {
  [ -n "$1" ] && certbot certonly --standalone -d "$1" \
    --non-interactive --agree-tos -m "$EMAIL"
}

cert "$TCP_TLS"
cert "$GRPC_TLS"
cert "$XHTTP_TLS"

# Reality domains не требуют сертификатов — они используют чужой TLS

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
# TLS SEEDS
# ======================

TCP_TLS_SEED=$(mlkem_seed)
GRPC_TLS_SEED=$(mlkem_seed)
XHTTP_TLS_SEED=$(mlkem_seed)

# ======================
# REALITY KEYS
# ======================

TCP_PRIV=$(x25519_priv)
GRPC_PRIV=$(x25519_priv)
XHTTP_PRIV=$(x25519_priv)

TCP_SID=$(sid)
GRPC_SID=$(sid)
XHTTP_SID=$(sid)

# ======================
# NGINX
# ======================

cat > /etc/nginx/nginx.conf <<EOF
user www-data;
worker_processes auto;
load_module modules/ngx_stream_module.so;

events { worker_connections 1024; }

stream {

    upstream tcp_tls    { server 127.0.0.1:5556; }
    upstream grpc_tls   { server 127.0.0.1:5555; }
    upstream xhttp_tls  { server 127.0.0.1:5557; }

    upstream tcp_reality   { server 127.0.0.1:5558; }
    upstream grpc_reality  { server 127.0.0.1:5559; }
    upstream xhttp_reality { server 127.0.0.1:5560; }

    map \$ssl_preread_server_name \$backend {
        hostnames;

        ${TCP_TLS}      tcp_tls;
        ${GRPC_TLS}     grpc_tls;
        ${XHTTP_TLS}    xhttp_tls;

        ${TCP_REALITY}   tcp_reality;
        ${GRPC_REALITY}  grpc_reality;
        ${XHTTP_REALITY} xhttp_reality;
    }

    server {
        listen 443;
        ssl_preread on;
        proxy_pass \$backend;
        proxy_protocol on;
    }
}

http {

EOF

add_http () {
  DOM=$1
  PORT=$2

  if [ -n "$DOM" ]; then
cat >> /etc/nginx/nginx.conf <<EOF
    server {
        listen 127.0.0.1:${PORT} ssl;
        server_name ${DOM};

        ssl_certificate     /etc/letsencrypt/live/${DOM}/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/${DOM}/privkey.pem;

        location / {
            root /var/www/html;
        }
    }
EOF
  fi
}

add_http "$TCP_REALITY"  6000
add_http "$GRPC_REALITY" 6001
add_http "$XHTTP_REALITY" 6002

cat >> /etc/nginx/nginx.conf <<EOF
}
EOF

nginx -t
systemctl restart nginx

# ======================
# XRAY CONFIG
# ======================

cat > /root/xray.json <<EOF
{
  "log": { "loglevel": "info" },

  "inbounds": [

    {
      "tag": "${COUNTRY} Autoselect",
      "port": 9997,
      "listen": "0.0.0.0",
      "protocol": "shadowsocks",
      "settings": {
        "clients": [],
        "network": "tcp,udp"
      },
      "sniffing": {
        "enabled": false,
        "destOverride": ["http", "tls", "quic"]
      }
    },

    {
      "tag": "${COUNTRY} ShadowSocks",
      "port": 9998,
      "listen": "0.0.0.0",
      "protocol": "shadowsocks",
      "settings": {
        "clients": [],
        "network": "tcp,udp"
      },
      "sniffing": {
        "enabled": false,
        "destOverride": ["http", "tls", "quic"]
      }
    },

    {
      "tag": "${COUNTRY} TCP TLS with vlessEncrypted",
      "port": 5556,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "mlkem768x25519plus.xorpub.600s.${TCP_TLS_SEED}"
      },
      "sniffing": {
        "enabled": false,
        "destOverride": ["http", "tls", "quic"]
      },
      "streamSettings": {
        "network": "tcp",
        "sockopt": {
          "acceptProxyProtocol": true
        },
        "security": "tls",
        "tlsSettings": {
          "serverName": "${TCP_TLS}",
          "certificates": [
            {
              "keyFile": "/etc/letsencrypt/live/${TCP_TLS}/privkey.pem",
              "certificateFile": "/etc/letsencrypt/live/${TCP_TLS}/fullchain.pem"
            }
          ]
        }
      }
    },

    {
      "tag": "${COUNTRY} gRPC TLS with vlessEncrypted",
      "port": 5555,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "mlkem768x25519plus.xorpub.600s.${GRPC_TLS_SEED}"
      },
      "sniffing": {
        "enabled": false,
        "destOverride": ["http", "tls", "quic"]
      },
      "streamSettings": {
        "network": "grpc",
        "sockopt": {
          "acceptProxyProtocol": true
        },
        "security": "tls",
        "tlsSettings": {
          "serverName": "${GRPC_TLS}",
          "certificates": [
            {
              "keyFile": "/etc/letsencrypt/live/${GRPC_TLS}/privkey.pem",
              "certificateFile": "/etc/letsencrypt/live/${GRPC_TLS}/fullchain.pem"
            }
          ]
        },
        "grpcSettings": {
          "serviceName": "grpc"
        }
      }
    },

    {
      "tag": "${COUNTRY} XHTTP TLS with vlessEncrypted",
      "port": 5557,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "mlkem768x25519plus.xorpub.600s.${XHTTP_TLS_SEED}"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      },
      "streamSettings": {
        "network": "xhttp",
        "sockopt": {
          "acceptProxyProtocol": true
        },
        "security": "tls",
        "tlsSettings": {
          "serverName": "${XHTTP_TLS}",
          "certificates": [
            {
              "keyFile": "/etc/letsencrypt/live/${XHTTP_TLS}/privkey.pem",
              "certificateFile": "/etc/letsencrypt/live/${XHTTP_TLS}/fullchain.pem"
            }
          ]
        },
        "xhttpSettings": {
          "host": "${XHTTP_TLS}",
          "mode": "stream-up",
          "path": "/xhttp",
          "extra": {
            "xmux": {
              "cMaxReuseTimes": 0,
              "maxConcurrency": "1",
              "maxConnections": 0,
              "hKeepAlivePeriod": 0,
              "hMaxRequestTimes": "600-900",
              "hMaxReusableSecs": "1800-3000"
            }
          }
        }
      }
    },

    {
      "tag": "${COUNTRY} TCP Reality",
      "port": 5558,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "sniffing": {
        "enabled": false,
        "destOverride": ["http", "tls", "quic"]
      },
      "streamSettings": {
        "network": "raw",
        "sockopt": {
          "acceptProxyProtocol": true
        },
        "security": "reality",
        "realitySettings": {
          "show": false,
          "xver": 0,
          "target": "6000",
          "spiderX": "",
          "serverNames": ["${TCP_REALITY}"],
          "privateKey": "${TCP_PRIV}",
          "shortIds": ["${TCP_SID}"]
        }
      }
    },

    {
      "tag": "${COUNTRY} gRPC Reality",
      "port": 5559,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "sniffing": {
        "enabled": false,
        "destOverride": ["http", "tls", "quic"]
      },
      "streamSettings": {
        "network": "grpc",
        "sockopt": {
          "acceptProxyProtocol": true
        },
        "security": "reality",
        "realitySettings": {
          "show": false,
          "xver": 0,
          "target": "6001",
          "spiderX": "",
          "serverNames": ["${GRPC_REALITY}"],
          "privateKey": "${GRPC_PRIV}",
          "shortIds": ["${GRPC_SID}"]
        },
        "grpcSettings": {
          "serviceName": "grpc"
        }
      }
    },

    {
      "tag": "${COUNTRY} XHTTP Reality",
      "port": 5560,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      },
      "streamSettings": {
        "network": "xhttp",
        "sockopt": {
          "acceptProxyProtocol": true
        },
        "security": "reality",
        "xhttpSettings": {
          "mode": "stream-up",
          "path": "/xhttp",
          "extra": {
            "xmux": {
              "cMaxReuseTimes": 0,
              "maxConcurrency": "1",
              "maxConnections": 0,
              "hKeepAlivePeriod": 0,
              "hMaxRequestTimes": "600-900",
              "hMaxReusableSecs": "1800-2500"
            },
            "headers": {},
            "security": "reality",
            "noSSEHeader": false,
            "noGRPCHeader": false,
            "xPaddingBytes": "100-1000"
          }
        },
        "realitySettings": {
          "show": false,
          "xver": 0,
          "target": "6002",
          "spiderX": "",
          "serverNames": ["${XHTTP_REALITY}"],
          "privateKey": "${XHTTP_PRIV}",
          "shortIds": ["${XHTTP_SID}"]
        }
      }
    }

  ],

  "outbounds": [
    { "tag": "DIRECT", "protocol": "freedom" },
    { "tag": "BLOCK",  "protocol": "blackhole" }
  ],

  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "domain": ["geosite:category-ru"],
        "outboundTag": "BLOCK"
      },
      {
        "type": "field",
        "protocol": ["bittorrent"],
        "outboundTag": "BLOCK"
      }
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

# Попытка 1: ix.io
IX_RESPONSE=$(curl -s -F 'f:1=</root/xray.json' http://ix.io 2>/dev/null || true)
if echo "$IX_RESPONSE" | grep -qE '^http'; then
  PASTE_URL="$IX_RESPONSE"
  echo "Загружено на ix.io: $PASTE_URL"
fi

# Попытка 2: paste.rs (если ix.io не ответил)
if [ -z "$PASTE_URL" ]; then
  PRS_RESPONSE=$(curl -s --data-binary @/root/xray.json https://paste.rs 2>/dev/null || true)
  if echo "$PRS_RESPONSE" | grep -qE '^https://paste\.rs/'; then
    PASTE_URL="$PRS_RESPONSE"
    echo "Загружено на paste.rs: $PASTE_URL"
  fi
fi

if [ -z "$PASTE_URL" ]; then
  echo "Не удалось загрузить онлайн. Конфиг доступен локально: /root/xray.json"
else
  echo ""
fi

echo ""
echo "--- Reality Public Keys ---"
echo "TCP  shortId: ${TCP_SID}"
echo "gRPC shortId: ${GRPC_SID}"
echo "XHTTP shortId: ${XHTTP_SID}"
echo "=============================="
