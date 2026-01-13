#!/bin/bash
set -euo pipefail

# ==============================================================================
# Bitbucket Data Center 9.4.15 Primary + Smart Mirror Setup (Rootless Podman)
# ==============================================================================
#
# This script automates the deployment of a Bitbucket Data Center Primary node
# and a Smart Mirror node using rootless Podman.
#
# Architecture:
# - Primary: Postgres 15, OpenSearch, Bitbucket (Port 8443 via Nginx)
# - Mirror:  Embedded H2, Bitbucket (Port 9443 via Nginx)
# - Proxy:   Nginx (Termination for SSL and routing)
# - Net:     Bridge network 'bb-net'
#
# Prerequisite:
# - Podman installed and functioning (rootless verification recommended)
# - Valid Bitbucket Data Center License Key
#
# ==============================================================================

# --- Configuration ---
BB_VERSION="9.4.15"
PG_VERSION="15"
NETWORK_NAME="bb-net"
BASE_DIR="$(pwd)/bb-deploy"
CERTS_DIR="${BASE_DIR}/certs"
CONFIG_DIR="${BASE_DIR}/config"
SSH_DIR="${CONFIG_DIR}/mirror-ssh"

# --- License Key ---
# REPLACE THIS WITH YOUR VALID LICENSE KEY
LICENSE_KEY="PASTE_YOUR_LICENSE_KEY_HERE"

# Ensure no newlines or whitespace in the key
LICENSE_KEY=$(echo "$LICENSE_KEY" | tr -d '\n' | tr -d '\r' | tr -d ' ')

if [ "$LICENSE_KEY" = "PASTE_YOUR_LICENSE_KEY_HERE" ]; then
  echo "Error: Please edit the script and insert a valid Trial/Full License Key in the LICENSE_KEY variable."
  exit 1
fi

echo "Info: Starting Bitbucket Data Center ${BB_VERSION} Setup..."

# --- Cleanup ---
echo "Info: Cleaning up previous runs..."
podman rm -f bb-primary bb-mirror bb-postgres bb-opensearch bb-nginx 2>/dev/null || true
podman volume rm bb-primary-home bb-mirror-home bb-postgres-data 2>/dev/null || true
podman network rm ${NETWORK_NAME} 2>/dev/null || true
rm -rf "${BASE_DIR}"

# --- Infrastructure ---
echo "Info: Creating infrastructure..."
mkdir -p "${CERTS_DIR}" "${CONFIG_DIR}" "${SSH_DIR}"
podman network create ${NETWORK_NAME}

# Generate Self-Signed Certificate
echo "Info: Generating SSL certificates..."
openssl req -x509 -newkey rsa:4096 -keyout "${CERTS_DIR}/privkey.pem" \
  -out "${CERTS_DIR}/fullchain.pem" -days 365 -nodes -subj "/CN=localhost" \
  -addext "subjectAltName = DNS:localhost,DNS:bb-primary,DNS:bb-mirror,DNS:bb-nginx" 2>/dev/null

chmod 644 "${CERTS_DIR}/privkey.pem" "${CERTS_DIR}/fullchain.pem"

# Generate SSH Keys for Mirror
echo "Info: Generating SSH keys for Mirror..."
ssh-keygen -t rsa -b 4096 -f "${SSH_DIR}/id_rsa" -N "" -q -C "mirror@localhost"
chmod 600 "${SSH_DIR}/id_rsa"
chmod 644 "${SSH_DIR}/id_rsa.pub"

# --- Services: Database & Search ---
echo "Info: Starting PostgreSQL & OpenSearch..."

# PostgreSQL 15
podman run -d --name bb-postgres \
  --network ${NETWORK_NAME} \
  -e POSTGRES_DB=bitbucket \
  -e POSTGRES_USER=bitbucket \
  -e POSTGRES_PASSWORD=bitbucket \
  -v bb-postgres-data:/var/lib/postgresql/data:Z \
  postgres:${PG_VERSION}

# OpenSearch (Single-node)
podman run -d --name bb-opensearch \
  --network ${NETWORK_NAME} \
  -e "discovery.type=single-node" \
  -e "DISABLE_SECURITY_PLUGIN=true" \
  -e "OPENSEARCH_JAVA_OPTS=-Xms512m -Xmx512m" \
  opensearchproject/opensearch:2.11.0

echo "Info: Waiting for PostgreSQL readiness..."
timeout 60s bash -c 'until podman exec bb-postgres pg_isready -U bitbucket; do sleep 2; done' || { echo "Error: Postgres unreachable"; exit 1; }

# --- Helper: Seed Volume ---
seed_volume() {
    local volume_name=$1
    local source_path=$2
    local dest_rel_path=$3
    local mode=$4
    local is_dir=${5:-false}

    echo "   Seeding $volume_name: $dest_rel_path..."
    
    local dest_full_path="/data/$dest_rel_path"
    local dest_dir
    dest_dir=$(dirname "$dest_full_path")
    
    local cmd=""
    if [ "$is_dir" = "true" ]; then
        cmd="mkdir -p $dest_full_path && cp -r /source/* $dest_full_path/ && chown -R 2003:2003 $dest_full_path && chmod -R $mode $dest_full_path"
    else
        cmd="mkdir -p $dest_dir && cp /source $dest_full_path && chown 2003:2003 $dest_full_path && chmod $mode $dest_full_path"
    fi

    podman run --rm \
      -v "$volume_name:/data" \
      -v "$source_path:/source:Z" \
      docker.io/library/alpine:latest sh -c "$cmd"
}

# Create volumes explicitly
podman volume create bb-primary-home
podman volume create bb-mirror-home

# --- Bitbucket Primary ---
echo "Info: Configuring Bitbucket Primary..."

cat > "${CONFIG_DIR}/bitbucket.properties" <<EOF
jdbc.driver=org.postgresql.Driver
jdbc.url=jdbc:postgresql://bb-postgres:5432/bitbucket
jdbc.user=bitbucket
jdbc.password=bitbucket

server.proxy-name=localhost
server.proxy-port=8443
server.scheme=https
server.secure=true

setup.baseUrl=https://localhost:8443
setup.displayName=Local Primary
setup.sysadmin.username=admin
setup.sysadmin.password=admin123
setup.license=${LICENSE_KEY}

plugin.ssh.baseurl=ssh://git@bb-nginx:7999

plugin.search.config.baseurl=http://bb-opensearch:9200
EOF

seed_volume "bb-primary-home" "${CONFIG_DIR}/bitbucket.properties" "shared/bitbucket.properties" "644"

# --- Bitbucket Mirror ---
echo "Info: Configuring Bitbucket Mirror..."

# Generate Mirror Configuration
cat > "${CONFIG_DIR}/bitbucket-mirror.properties" <<EOF
application.mode=mirror

server.proxy-name=localhost
server.proxy-port=9443
server.scheme=https
server.secure=true

setup.baseUrl=https://bb-nginx:8443
setup.displayName=Local Mirror

# Mirror connects to Primary via Nginx HTTPS
plugin.mirroring.upstream.url=https://bb-nginx:443
plugin.mirroring.upstream.type=server
EOF

seed_volume "bb-mirror-home" "${CONFIG_DIR}/bitbucket-mirror.properties" "shared/bitbucket.properties" "644"
seed_volume "bb-mirror-home" "${SSH_DIR}" ".ssh" "700" "true"

# Fix SSH permissions
podman run --rm -v bb-mirror-home:/data docker.io/library/alpine:latest \
    sh -c "chmod 600 /data/.ssh/id_rsa && chmod 644 /data/.ssh/id_rsa.pub && chown -R 2003:2003 /data/.ssh"

# Start Primary
# Port 7999 is only exposed internally to the network; Nginx proxies it from the host.
# We map 'localhost' to the host gateway so the container can reach Nginx via 'https://localhost:9443'
echo "Info: Starting Bitbucket Primary..."
podman run -d --name bb-primary \
  --network ${NETWORK_NAME} \
  --add-host "localhost:host-gateway" \
  -v bb-primary-home:/var/atlassian/application-data/bitbucket:Z \
  -e ELASTICSEARCH_ENABLED=false \
  docker.io/atlassian/bitbucket:${BB_VERSION}

# Start Mirror
echo "Info: Starting Bitbucket Mirror..."
# Note: We FORCE mirror mode via JVM argument to prevent any config file race conditions or defaults.
podman run -d --name bb-mirror \
  --network ${NETWORK_NAME} \
  --add-host "localhost:host-gateway" \
  -v bb-mirror-home:/var/atlassian/application-data/bitbucket:Z \
  -e JVM_SUPPORT_RECOMMENDED_ARGS="-Dapplication.mode=mirror" \
  docker.io/atlassian/bitbucket:${BB_VERSION}

# --- Certificate Trust & Reliability ---
# To prevent database locks during restarts, we wait for the DB to initialize before restarting for certs.

import_cert() {
    local container=$1
    echo "Info: Importing SSL cert into $container..."
    
    # Wait for container to be completely running
    until [ "$(podman inspect -f '{{.State.Status}}' $container 2>/dev/null)" == "running" ]; do
        sleep 2
    done
    
    # Copy and Import
    podman cp "${CERTS_DIR}/fullchain.pem" "$container:/tmp/rootCA.pem"
    
    podman exec -u 0 "$container" sh -c '
        keytool -import -trustcacerts -alias local-root-ca \
        -file /tmp/rootCA.pem \
        -keystore "$JAVA_HOME/lib/security/cacerts" \
        -storepass changeit -noprompt' >/dev/null 2>&1 || echo "   Warning: Cert might already exist in $container"
}

# 1. Primary
echo "Info: Waiting for Primary to initialize..."
import_cert "bb-primary"
echo "Info: Restarting Primary to apply truststore..."
podman restart bb-primary

# 2. Mirror (Critical Wait Logic)
echo "Info: Waiting for Mirror Database initialization (preventing lock exceptions)..."
# Loop until we get *any* HTTP response from the internal port
until podman exec bb-mirror curl -s -o /dev/null -w "%{http_code}" http://localhost:7990/status | grep -q '200\|401\|503'; do
  sleep 5
done
echo "   Mirror DB is ready."

import_cert "bb-mirror"
echo "Info: Restarting Mirror to apply truststore..."
podman restart bb-mirror

# --- Nginx Proxy ---
echo "Info: Starting Nginx Proxy..."

cat > "${CONFIG_DIR}/nginx.conf" <<EOF
events { worker_connections 1024; }

http {
    proxy_read_timeout 300;
    proxy_connect_timeout 300;
    proxy_send_timeout 300;

    server {
        listen 443 ssl;
        server_name localhost bb-primary bb-nginx;

        ssl_certificate /etc/nginx/certs/fullchain.pem;
        ssl_certificate_key /etc/nginx/certs/privkey.pem;

        location / {
            proxy_pass http://bb-primary:7990;
            proxy_set_header X-Forwarded-Host \$host;
            proxy_set_header X-Forwarded-Server \$host;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-Proto https;
            
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
        }
    }

    server {
        listen 8443 ssl;
        server_name localhost bb-mirror;

        ssl_certificate /etc/nginx/certs/fullchain.pem;
        ssl_certificate_key /etc/nginx/certs/privkey.pem;

        location / {
            proxy_pass http://bb-mirror:7990;
            proxy_set_header X-Forwarded-Host \$host;
            proxy_set_header X-Forwarded-Server \$host;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-Proto https;
        }
    }
}

stream {
    server {
        listen 7999;
        proxy_pass bb-primary:7999;
    }
}
EOF

podman run -d --name bb-nginx \
  --network ${NETWORK_NAME} \
  -p 8443:443 \
  -p 9443:8443 \
  -p 7999:7999 \
  -v "${CONFIG_DIR}/nginx.conf":/etc/nginx/nginx.conf:Z \
  -v "${CERTS_DIR}":/etc/nginx/certs:Z \
  nginx:latest

# --- Validation & Automation ---
echo "Info: Bitbucket Setup in progress. Waiting for services to come online..."
echo "      (This usually takes 2-4 minutes for the application to boot)"

wait_for_status() {
    local url=$1
    local expected=$2
    local label=$3
    local count=0
    local max_retries=90 # ~7.5 mins

    echo -n "   Waiting for $label..."
    until curl -s -k "$url/status" | grep -q "$expected"; do
        if [ $count -ge $max_retries ]; then
            echo " Error: Timeout waiting for $label"
            return 1
        fi
        sleep 5
        count=$((count+1))
    done
    echo " Ready!"
}

# Wait for Primary
wait_for_status "https://localhost:8443" "RUNNING" "Bitbucket Primary"

echo "Info: Automating Setup steps..."

# Create Project "DEMO"
echo "   Creating Project DEMO..."
curl -s -k -u admin:admin123 -X POST -H "Content-Type: application/json" \
  -d '{"key": "DEMO", "name": "Demo Project", "description": "Auto-created by setup script"}' \
  https://localhost:8443/rest/api/1.0/projects >/dev/null || true

# Create Repo "repo-1"
echo "   Creating Repository repo-1..."
curl -s -k -u admin:admin123 -X POST -H "Content-Type: application/json" \
  -d '{"name": "repo-1", "scmId": "git", "forkable": true}' \
  https://localhost:8443/rest/api/1.0/projects/DEMO/repos >/dev/null || true

# Wait for Mirror
# Note: Mirror is often ready faster than Primary, but we check anyway.
wait_for_status "https://localhost:9443" "FIRST_RUN\|RUNNING" "Bitbucket Mirror"

echo ""
echo "=========================================="
echo "Setup Complete!"
echo "=========================================="
echo "Primary: https://localhost:8443 (admin/admin123)"
echo "Mirror:  https://localhost:9443"
echo "SSH Port: 7999 (Exposed via Nginx)"
echo ""
echo "MANUAL STEPS REQUIRED:"
echo "1. Log into Primary at https://localhost:8443"
echo "2. Navigate to: Administration (Gear) -> Mirrors"
echo "3. Authorize the 'Local Mirror' request."
echo "4. Click on 'Local Mirror' in the list."
echo "5. Add 'DEMO' project to the mirror configuration."
echo "6. Verify sync status."
echo ""
echo "Note: Self-signed certificates will cause browser warnings. Proceed safely."
echo "=========================================="
