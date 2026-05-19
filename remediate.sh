#!/usr/bin/env bash
# Remediation script — copies fix-mysql.sh / fix-web.sh to the two VMs
# and runs them. Reads VM IPs from `az` and creds from .secrets.env.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOURCE_GROUP="${RESOURCE_GROUP:-o11y-lamp-rg}"
ADMIN_USER="${ADMIN_USER:-azureuser}"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/.secrets.env"

WEB_IP="$(az network public-ip show -g "$RESOURCE_GROUP" -n vm-web-pip   --query ipAddress -o tsv)"
DB_IP="$(az network public-ip show  -g "$RESOURCE_GROUP" -n vm-mysql-pip --query ipAddress -o tsv)"

echo "WEB=$WEB_IP DB=$DB_IP"

# Build env header common to both fix scripts
ENV_HEADER=$(cat <<EOF
export SPLUNK_REALM='$SPLUNK_REALM'
export SPLUNK_ACCESS_TOKEN='$SPLUNK_ACCESS_TOKEN'
export APP_PWD='$APP_PWD'
export OTEL_PWD='$OTEL_PWD'
EOF
)

run_remote () {
  local ip="$1"; local script="$2"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -euo pipefail'
    echo "$ENV_HEADER"
    cat "$script"
  } | ssh -o StrictHostKeyChecking=no "$ADMIN_USER@$ip" 'sudo bash -s'
}

echo "==> Fixing MySQL VM ($DB_IP)"
run_remote "$DB_IP" "$SCRIPT_DIR/fix-mysql.sh"

echo "==> Fixing Web VM ($WEB_IP)"
run_remote "$WEB_IP" "$SCRIPT_DIR/fix-web.sh"

echo "==> Done. Now generate traffic:"
echo "  for i in {1..50}; do curl -s -o /dev/null http://$WEB_IP/; done"
