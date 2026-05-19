#!/usr/bin/env bash
# Make APM <-> Infrastructure correlate by forcing host.name on metrics to
# match the short hostname that traces already carry.
#
# Root cause: in [system, env, azure] the azure detector overrode host.name
# with the FQDN on the metrics pipeline, while traces (coming from the PHP
# SDK with its own host.name=vm-web) kept the short name due to override:false.
# Result: APM spans = host.name "vm-web", Infra metrics = host.name "<fqdn>".
#
# Fix: disable the azure detector's host.name attribute so the system
# detector's short hostname wins for both pipelines.
set -euo pipefail

: "${SPLUNK_REALM:?}"
: "${SPLUNK_ACCESS_TOKEN:?}"

WEB_IP="${WEB_IP:-20.123.149.120}"
DB_IP="${DB_IP:-20.126.37.32}"
SSH_USER="${SSH_USER:-azureuser}"

patch_host_name_on() {
    local ip="$1"
    echo "==> Patching collector config on ${ip}..."
    ssh -o StrictHostKeyChecking=no "${SSH_USER}@${ip}" 'sudo python3 - <<PY
import yaml
p = "/etc/otel/collector/custom-config.yaml"
c = yaml.safe_load(open(p))

# 1) Normalize host.name to the short Azure VM name (azure.vm.name = vm-web / vm-mysql)
#    The Azure detector forces host.name to the cloud-internal FQDN, which never
#    matches what the PHP SDK emits on spans (short hostname). Splunk APM<->Infra
#    correlation requires identical host.name on both, so we overwrite it here.
c["processors"]["resource/normalize_host"] = {
    "attributes": [
        {"key": "host.name", "from_attribute": "azure.vm.name", "action": "upsert"},
    ]
}

for pipe in ("metrics", "traces"):
    procs = c["service"]["pipelines"][pipe]["processors"]
    if "resource/normalize_host" in procs:
        procs.remove("resource/normalize_host")
    # Insert right after resourcedetection so azure.vm.name is available
    idx = procs.index("resourcedetection") + 1
    procs.insert(idx, "resource/normalize_host")

open(p, "w").write(yaml.safe_dump(c, sort_keys=False))
print("patched")
PY
sudo systemctl restart splunk-otel-collector
sleep 3
sudo systemctl is-active splunk-otel-collector
'
}

patch_host_name_on "${WEB_IP}"
patch_host_name_on "${DB_IP}"

echo
echo "==> Generating fresh traffic against web VM..."
for i in $(seq 1 20); do
    curl -s -o /dev/null -X POST -d "name=Corr${i}&email=c${i}@x.io&message=corr-${i}" "http://${WEB_IP}/" &
done
wait
sleep 10

echo
echo "==> Verifying host.name dimension on signalfx exporter (the value Splunk Infra uses)..."
for ip in "${WEB_IP}" "${DB_IP}"; do
    echo "--- ${ip} ---"
    ssh -o StrictHostKeyChecking=no "${SSH_USER}@${ip}" 'sudo journalctl -u splunk-otel-collector --since "30 sec ago" --no-pager | grep -oE "\"azure_resource_id\"|host\.name[^,}]*" | sort -u | head'
done

echo
echo "Done. In Splunk Observability:"
echo "  APM > Services > php-lamp-demo > pick a trace > Related Content > Infrastructure"
echo "  should now light up the vm-web host card."
