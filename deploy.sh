#!/usr/bin/env bash
# Deploy two Azure Ubuntu VMs:
#   * vm-mysql : MySQL 8 + Splunk OTel collector with mysql receiver
#   * vm-web   : Apache + PHP + Splunk OTel PHP auto-instrumentation + apache receiver
#
# Public access: vm-web is reachable on port 80 from the Internet.
#                vm-mysql is reachable from vm-web only (VNet) and SSH from anywhere.
#
# Usage:  ./deploy.sh           (uses values below)
#         RESOURCE_GROUP=foo ./deploy.sh
#
# Requires: az CLI logged in, openssl, awk, sed.

set -euo pipefail

# ---------- Config (override via env) ----------
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-e77116d5-21bd-4488-ba12-20faa5c11605}"
RESOURCE_GROUP="${RESOURCE_GROUP:-o11y-lamp-rg}"
LOCATION="${LOCATION:-westeurope}"
VM_SIZE="${VM_SIZE:-Standard_D2s_v3}"
ADMIN_USER="${ADMIN_USER:-azureuser}"
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_rsa.pub}"
IMAGE="${IMAGE:-Canonical:ubuntu-24_04-lts:server:latest}"

SPLUNK_REALM="${SPLUNK_REALM:-eu0}"
SPLUNK_ACCESS_TOKEN="${SPLUNK_ACCESS_TOKEN:?Set SPLUNK_ACCESS_TOKEN (e.g. via .secrets.env) before running}"

VNET_NAME="lamp-vnet"
SUBNET_NAME="lamp-subnet"
NSG_WEB="nsg-web"
NSG_DB="nsg-db"
VM_WEB="vm-web"
VM_DB="vm-mysql"
MYSQL_PRIVATE_IP="10.42.1.10"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- Pre-flight ----------
command -v az >/dev/null || { echo "az CLI required"; exit 1; }
command -v openssl >/dev/null || { echo "openssl required"; exit 1; }
[[ -f "$SSH_KEY_PATH" ]] || { echo "SSH public key not found at $SSH_KEY_PATH"; exit 1; }

echo "==> Using subscription $SUBSCRIPTION_ID"
az account set --subscription "$SUBSCRIPTION_ID"

# Random DB passwords (URL/shell-safe alphanumerics)
APP_PWD="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)"
OTEL_PWD="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)"

echo "==> Generated MySQL passwords (saved to $SCRIPT_DIR/.secrets.env)"
cat > "$SCRIPT_DIR/.secrets.env" <<EOF
APP_PWD=$APP_PWD
OTEL_PWD=$OTEL_PWD
SPLUNK_REALM=$SPLUNK_REALM
SPLUNK_ACCESS_TOKEN=$SPLUNK_ACCESS_TOKEN
EOF
chmod 600 "$SCRIPT_DIR/.secrets.env"

# ---------- Resource group + network ----------
echo "==> [1/8] Resource group"
az group create -n "$RESOURCE_GROUP" -l "$LOCATION" --only-show-errors >/dev/null

echo "==> [2/8] VNet + subnet"
az network vnet create -g "$RESOURCE_GROUP" -n "$VNET_NAME" \
  --address-prefixes 10.42.0.0/16 \
  --subnet-name "$SUBNET_NAME" --subnet-prefixes 10.42.1.0/24 \
  --only-show-errors >/dev/null

echo "==> [3/8] NSGs"
az network nsg create -g "$RESOURCE_GROUP" -n "$NSG_WEB" --only-show-errors >/dev/null
az network nsg create -g "$RESOURCE_GROUP" -n "$NSG_DB"  --only-show-errors >/dev/null

az network nsg rule create -g "$RESOURCE_GROUP" --nsg-name "$NSG_WEB" -n allow-ssh \
  --priority 1000 --access Allow --direction Inbound --protocol Tcp \
  --source-address-prefixes '*' --source-port-ranges '*' \
  --destination-address-prefixes '*' --destination-port-ranges 22 --only-show-errors >/dev/null
az network nsg rule create -g "$RESOURCE_GROUP" --nsg-name "$NSG_WEB" -n allow-http \
  --priority 1010 --access Allow --direction Inbound --protocol Tcp \
  --source-address-prefixes '*' --source-port-ranges '*' \
  --destination-address-prefixes '*' --destination-port-ranges 80 --only-show-errors >/dev/null

az network nsg rule create -g "$RESOURCE_GROUP" --nsg-name "$NSG_DB" -n allow-ssh \
  --priority 1000 --access Allow --direction Inbound --protocol Tcp \
  --source-address-prefixes '*' --source-port-ranges '*' \
  --destination-address-prefixes '*' --destination-port-ranges 22 --only-show-errors >/dev/null
az network nsg rule create -g "$RESOURCE_GROUP" --nsg-name "$NSG_DB" -n allow-mysql-from-vnet \
  --priority 1010 --access Allow --direction Inbound --protocol Tcp \
  --source-address-prefixes 10.42.0.0/16 --source-port-ranges '*' \
  --destination-address-prefixes '*' --destination-port-ranges 3306 --only-show-errors >/dev/null

# ---------- Cloud-init rendering ----------
echo "==> [4/8] Rendering cloud-init"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# MySQL cloud-init
sed \
  -e "s|__APP_PWD__|$APP_PWD|g" \
  -e "s|__OTEL_PWD__|$OTEL_PWD|g" \
  -e "s|__REALM__|$SPLUNK_REALM|g" \
  -e "s|__TOKEN__|$SPLUNK_ACCESS_TOKEN|g" \
  "$SCRIPT_DIR/cloud-init-mysql.yaml.tmpl" > "$TMP_DIR/cloud-init-mysql.yaml"

# Web cloud-init — embed index.php with 6-space indent (under content: |)
sed 's/^/      /' "$SCRIPT_DIR/app/index.php" > "$TMP_DIR/index.php.indented"
python3 - "$SCRIPT_DIR/cloud-init-web.yaml.tmpl" "$TMP_DIR/index.php.indented" <<'PY' > "$TMP_DIR/web.merged"
import sys
tmpl = open(sys.argv[1]).read()
php  = open(sys.argv[2]).read()
sys.stdout.write(tmpl.replace("__INDEX_PHP__", php.rstrip("\n")))
PY
sed \
    -e "s|__APP_PWD__|$APP_PWD|g" \
    -e "s|__MYSQL_IP__|$MYSQL_PRIVATE_IP|g" \
    -e "s|__REALM__|$SPLUNK_REALM|g" \
    -e "s|__TOKEN__|$SPLUNK_ACCESS_TOKEN|g" \
  "$TMP_DIR/web.merged" > "$TMP_DIR/cloud-init-web.yaml"

# ---------- MySQL VM ----------
echo "==> [5/8] Creating $VM_DB"
az network nic create -g "$RESOURCE_GROUP" -n "${VM_DB}-nic" \
  --vnet-name "$VNET_NAME" --subnet "$SUBNET_NAME" \
  --network-security-group "$NSG_DB" \
  --private-ip-address "$MYSQL_PRIVATE_IP" \
  --only-show-errors >/dev/null

az network public-ip create -g "$RESOURCE_GROUP" -n "${VM_DB}-pip" \
  --sku Standard --allocation-method Static --only-show-errors >/dev/null
az network nic ip-config update -g "$RESOURCE_GROUP" \
  --nic-name "${VM_DB}-nic" -n ipconfig1 \
  --public-ip-address "${VM_DB}-pip" --only-show-errors >/dev/null

az vm create -g "$RESOURCE_GROUP" -n "$VM_DB" \
  --image "$IMAGE" --size "$VM_SIZE" \
  --admin-username "$ADMIN_USER" --ssh-key-values "$SSH_KEY_PATH" \
  --nics "${VM_DB}-nic" \
  --custom-data "$TMP_DIR/cloud-init-mysql.yaml" \
  --only-show-errors >/dev/null

# ---------- Web VM ----------
echo "==> [6/8] Creating $VM_WEB"
az network public-ip create -g "$RESOURCE_GROUP" -n "${VM_WEB}-pip" \
  --sku Standard --allocation-method Static --only-show-errors >/dev/null

az network nic create -g "$RESOURCE_GROUP" -n "${VM_WEB}-nic" \
  --vnet-name "$VNET_NAME" --subnet "$SUBNET_NAME" \
  --network-security-group "$NSG_WEB" \
  --public-ip-address "${VM_WEB}-pip" \
  --only-show-errors >/dev/null

az vm create -g "$RESOURCE_GROUP" -n "$VM_WEB" \
  --image "$IMAGE" --size "$VM_SIZE" \
  --admin-username "$ADMIN_USER" --ssh-key-values "$SSH_KEY_PATH" \
  --nics "${VM_WEB}-nic" \
  --custom-data "$TMP_DIR/cloud-init-web.yaml" \
  --only-show-errors >/dev/null

# ---------- Output ----------
echo "==> [7/8] Fetching public IPs"
WEB_IP="$(az network public-ip show -g "$RESOURCE_GROUP" -n "${VM_WEB}-pip" --query ipAddress -o tsv)"
DB_IP="$(az network public-ip show  -g "$RESOURCE_GROUP" -n "${VM_DB}-pip"  --query ipAddress -o tsv)"

echo "==> [8/8] Done"
cat <<EOF

============================================================
  Deployment complete
============================================================
  Resource group : $RESOURCE_GROUP ($LOCATION)
  Splunk realm   : $SPLUNK_REALM

  Web (Apache+PHP) : http://$WEB_IP/        (cloud-init ~5-8 min)
  Web SSH          : ssh $ADMIN_USER@$WEB_IP
  MySQL VM SSH     : ssh $ADMIN_USER@$DB_IP
  MySQL private IP : $MYSQL_PRIVATE_IP

  Secrets saved to : $SCRIPT_DIR/.secrets.env
  App DB user      : appuser / (see .secrets.env)
  OTel DB user     : otel    / (see .secrets.env, localhost only)

  Splunk UI:
    APM     -> service "php-lamp-demo"
    Infra   -> hosts $VM_WEB and $VM_DB (env=demo-o11y-lamp)
    Metrics -> apache.* (web) and mysql.* (db)

  Tail cloud-init progress (wait until "finished" message):
    ssh $ADMIN_USER@$WEB_IP sudo tail -f /var/log/cloud-init-output.log
    ssh $ADMIN_USER@$DB_IP  sudo tail -f /var/log/cloud-init-output.log
============================================================
EOF
