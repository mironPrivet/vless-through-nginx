#!/bin/bash
set -e

echo "=== Xray Installer ==="

# ======================
# INPUT
# ======================

read -p "Для какой страны делаем конфиг? (латиница): " COUNTRY

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

# ======================
# CERTS
# ======================

cert () {
  [ -n "$1" ] && certbot certonly --standalone -d "$1" \
    --non-interactive --agree-tos -m "$EMAIL"
}

cert "$TCP_REALITY"
cert "$GRPC_REALITY"
cert "$XHTTP_REALITY"
cert "$TCP_TLS"
cert "$GRPC_TLS"
cert "$XHTTP_TLS"

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

    upstream tcp_tls { server 127.0.0.1:5556; }
    upstream grpc_tls { server 127.0.0.1:5555; }
    upstream xhttp_tls { server 127.0.0.1:5557; }

    upstream tcp_reality { server 127.0.0.1:5558; }
    upstream grpc_reality { server 127.0.0.1:5559; }
    upstream xhttp_reality { server 127.0.0.1:5560; }

    map \$ssl_preread_server_name \$backend {
        hostnames;

        ${TCP_TLS} tcp_tls;
        ${GRPC_TLS} grpc_tls;
        ${XHTTP_TLS} xhttp_tls;

        ${TCP_REALITY} tcp_reality;
        ${GRPC_REALITY} grpc_reality;
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
TAG=$3

if [ -n "$DOM" ]; then
cat >> /etc/nginx/nginx.conf <<EOF
server {
    listen 127.0.0.1:${PORT} ssl;
    server_name ${DOM};

    ssl_certificate /etc/letsencrypt/live/${DOM}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOM}/privkey.pem;

    location / {
        root /var/www/html;
    }
}
EOF
fi
}

add_http "$TCP_REALITY" 6000 "${COUNTRY} TCP Reality"
add_http "$GRPC_REALITY" 6001 "${COUNTRY} gRPC Reality"

cat >> /etc/nginx/nginx.conf <<EOF
}
EOF

nginx -t
systemctl restart nginx

# ======================
# XRAY CONFIG (FULL RESTORED)
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
      "streamSettings": {
        "network": "grpc",
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
      "streamSettings": {
        "network": "xhttp",
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
      "streamSettings": {
        "security": "reality",
        "realitySettings": {
          "target": "6000",
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
      "streamSettings": {
        "security": "reality",
        "realitySettings": {
          "target": "6001",
          "serverNames": ["${GRPC_REALITY}"],
          "privateKey": "${GRPC_PRIV}",
          "shortIds": ["${GRPC_SID}"]
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
      "streamSettings": {
        "security": "reality",
        "realitySettings": {
          "target": "6002",
          "serverNames": ["${XHTTP_REALITY}"],
          "privateKey": "${XHTTP_PRIV}",
          "shortIds": ["${XHTTP_SID}"]
        }
      }
    }

  ],

  "outbounds": [
    { "tag": "DIRECT", "protocol": "freedom" },
    { "tag": "BLOCK", "protocol": "blackhole" }
  ]
}
EOF

echo ""
echo "=============================="
echo "DONE"
echo "Country: $COUNTRY"
echo "Config saved: /root/xray.json"
echo "=============================="
