#!/usr/bin/env bash
# Redeploy ONLY the LAMP web VM as RHEL 9, reusing the existing VNet, NSG,
# public IP, NIC, and MySQL VM from the original Ubuntu deployment.
#
# Prereqs:
#   * .secrets.env exists (contains APP_PWD, SPLUNK_REALM, SPLUNK_ACCESS_TOKEN)
#   * o11y-lamp-rg resource group exists with vm-mysql + lamp-vnet + nsg-web + vm-web-{nic,pip}
#
# What it does:
#   1) Loads .secrets.env
#   2) Ensures vm-mysql is started
#   3) Deletes the old Ubuntu vm-web and its OS disk
#   4) Renders cloud-init-web-rhel.yaml with index.php and secrets
#   5) Creates a new RHEL 9 vm-web attached to the existing NIC
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- Config (override via env) ----------
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-e77116d5-21bd-4488-ba12-20faa5c11605}"
RESOURCE_GROUP="${RESOURCE_GROUP:-o11y-lamp-rg}"
LOCATION="${LOCATION:-westeurope}"
VM_SIZE="${VM_SIZE:-Standard_D2s_v3}"
ADMIN_USER="${ADMIN_USER:-azureuser}"
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_rsa.pub}"
# RHEL 9 PAYG, gen1 (max compatibility with D-series v3)
IMAGE="${IMAGE:-RedHat:RHEL:9-lvm:latest}"

VM_WEB="vm-web"
VM_DB="vm-mysql"
MYSQL_PRIVATE_IP="${MYSQL_PRIVATE_IP:-10.42.1.10}"

# ---------- Pre-flight ----------
command -v az >/dev/null || { echo "az CLI required"; exit 1; }
[[ -f "$SSH_KEY_PATH" ]] || { echo "SSH public key not found at $SSH_KEY_PATH"; exit 1; }
[[ -f "$SCRIPT_DIR/.secrets.env" ]] || { echo "Missing $SCRIPT_DIR/.secrets.env (run deploy.sh once first)"; exit 1; }

# shellcheck disable=SC1091
set -a; source "$SCRIPT_DIR/.secrets.env"; set +a
: "${APP_PWD:?APP_PWD missing in .secrets.env}"
: "${SPLUNK_REALM:?SPLUNK_REALM missing in .secrets.env}"
: "${SPLUNK_ACCESS_TOKEN:?SPLUNK_ACCESS_TOKEN missing in .secrets.env}"

az account set --subscription "$SUBSCRIPTION_ID"

echo "==> [1/5] Ensuring $VM_DB is started"
DB_STATE="$(az vm get-instance-view -g "$RESOURCE_GROUP" -n "$VM_DB" \
            --query "instanceView.statuses[?starts_with(code,'PowerState/')].code | [0]" -o tsv)"
if [[ "$DB_STATE" != "PowerState/running" ]]; then
  az vm start -g "$RESOURCE_GROUP" -n "$VM_DB" --only-show-errors >/dev/null
fi

echo "==> [2/5] Deleting old Ubuntu $VM_WEB (keeping NIC + Public IP)"
OLD_OS_DISK="$(az vm show -g "$RESOURCE_GROUP" -n "$VM_WEB" \
              --query "storageProfile.osDisk.name" -o tsv 2>/dev/null || true)"
if [[ -n "$OLD_OS_DISK" ]]; then
  az vm delete -g "$RESOURCE_GROUP" -n "$VM_WEB" --yes --only-show-errors >/dev/null
  az disk delete -g "$RESOURCE_GROUP" -n "$OLD_OS_DISK" --yes --only-show-errors >/dev/null || true
fi

echo "==> [3/5] Rendering cloud-init for RHEL"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Indent index.php under cloud-init "content: |" (6-space block)
sed 's/^/      /' "$SCRIPT_DIR/app/index.php" > "$TMP_DIR/index.php.indented"

python3 - "$SCRIPT_DIR/cloud-init-web-rhel.yaml.tmpl" "$TMP_DIR/index.php.indented" <<'PY' > "$TMP_DIR/web.merged"
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
  "$TMP_DIR/web.merged" > "$TMP_DIR/cloud-init-web-rhel.yaml"

echo "==> [4/5] Creating RHEL $VM_WEB on existing NIC"
az vm create -g "$RESOURCE_GROUP" -n "$VM_WEB" \
  --image "$IMAGE" --size "$VM_SIZE" \
  --admin-username "$ADMIN_USER" --ssh-key-values "$SSH_KEY_PATH" \
  --nics "${VM_WEB}-nic" \
  --custom-data "$TMP_DIR/cloud-init-web-rhel.yaml" \
  --only-show-errors >/dev/null

WEB_IP="$(az network public-ip show -g "$RESOURCE_GROUP" -n "${VM_WEB}-pip" --query ipAddress -o tsv)"
DB_IP="$(az network public-ip show  -g "$RESOURCE_GROUP" -n "${VM_DB}-pip"  --query ipAddress -o tsv)"

echo "==> [5/5] Done"
cat <<EOF

============================================================
  RHEL LAMP redeploy complete
============================================================
  Image            : $IMAGE
  Resource group   : $RESOURCE_GROUP ($LOCATION)
  Web (httpd+PHP)  : http://$WEB_IP/        (cloud-init ~6-10 min)
  Web SSH          : ssh $ADMIN_USER@$WEB_IP
  MySQL VM SSH     : ssh $ADMIN_USER@$DB_IP
  MySQL private IP : $MYSQL_PRIVATE_IP

  Tail setup progress on the web VM:
    ssh $ADMIN_USER@$WEB_IP "sudo tail -f /var/log/setup-lamp-otel.log"

  Splunk UI:
    APM     -> service "php-lamp-demo"
    Infra   -> host "$VM_WEB" (env=demo-o11y-lamp)
    Metrics -> apache.* (web) and mysql.* (db, from unchanged Ubuntu VM)
============================================================
EOF
