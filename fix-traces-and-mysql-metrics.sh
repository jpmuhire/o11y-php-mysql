#!/usr/bin/env bash
# Push corrected collector configs to both VMs.
#  * web: traces_endpoint = APM OTLP path (/v2/trace/otlp)
#  * db : same fix + enable optional mysql metrics
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RG="${RESOURCE_GROUP:-o11y-lamp-rg}"
USR="${ADMIN_USER:-azureuser}"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/.secrets.env"

WEB_IP="$(az network public-ip show -g "$RG" -n vm-web-pip   --query ipAddress -o tsv)"
DB_IP="$(az network public-ip show  -g "$RG" -n vm-mysql-pip --query ipAddress -o tsv)"

push () {
  local ip="$1"; local payload="$2"
  ssh -o StrictHostKeyChecking=no "$USR@$ip" "sudo tee /etc/otel/collector/custom-config.yaml >/dev/null && sudo systemctl restart splunk-otel-collector && sleep 3 && sudo systemctl is-active splunk-otel-collector && sudo journalctl -u splunk-otel-collector -n 15 --no-pager | tail -10" <<<"$payload"
}

WEB_CFG=$(cat <<EOF
extensions:
  health_check:
    endpoint: 0.0.0.0:13133
receivers:
  hostmetrics:
    collection_interval: 30s
    scrapers: {cpu: {}, disk: {}, filesystem: {}, load: {}, memory: {}, network: {}, paging: {}, processes: {}}
  apache:
    endpoint: http://localhost:80/server-status?auto
    collection_interval: 30s
  otlp:
    protocols:
      grpc: {endpoint: 0.0.0.0:4317}
      http: {endpoint: 0.0.0.0:4318}
processors:
  batch: {}
  resourcedetection:
    detectors: [system, env, azure]
    override: false
  resource/host:
    attributes:
      - {key: deployment.environment, value: demo-o11y-lamp, action: upsert}
exporters:
  signalfx:
    access_token: "\${SPLUNK_ACCESS_TOKEN}"
    realm: "\${SPLUNK_REALM}"
    sync_host_metadata: true
  otlphttp/traces:
    traces_endpoint: "https://ingest.\${SPLUNK_REALM}.signalfx.com/v2/trace/otlp"
    headers:
      X-SF-Token: "\${SPLUNK_ACCESS_TOKEN}"
service:
  extensions: [health_check]
  pipelines:
    metrics:
      receivers: [hostmetrics, apache]
      processors: [resourcedetection, resource/host, batch]
      exporters: [signalfx]
    traces:
      receivers: [otlp]
      processors: [resourcedetection, resource/host, batch]
      exporters: [otlphttp/traces]
EOF
)

DB_CFG=$(cat <<EOF
extensions:
  health_check:
    endpoint: 0.0.0.0:13133
receivers:
  hostmetrics:
    collection_interval: 30s
    scrapers: {cpu: {}, disk: {}, filesystem: {}, load: {}, memory: {}, network: {}, paging: {}, processes: {}}
  mysql:
    endpoint: localhost:3306
    username: otel
    password: "$OTEL_PWD"
    collection_interval: 30s
    metrics:
      mysql.connection.count:
        enabled: true
      mysql.connection.errors:
        enabled: true
      mysql.client.network.io:
        enabled: true
      mysql.query.count:
        enabled: true
      mysql.query.slow.count:
        enabled: true
      mysql.query.client.count:
        enabled: true
      mysql.commands:
        enabled: true
      mysql.prepared_statements:
        enabled: true
      mysql.replica.time_behind_source:
        enabled: true
      mysql.replica.sql_delay:
        enabled: true
      mysql.statement_event.count:
        enabled: true
      mysql.statement_event.wait.time:
        enabled: true
      mysql.table.io.wait.count:
        enabled: true
      mysql.table.io.wait.time:
        enabled: true
      mysql.table.lock_wait.read.count:
        enabled: true
      mysql.table.lock_wait.read.time:
        enabled: true
      mysql.table.lock_wait.write.count:
        enabled: true
      mysql.table.lock_wait.write.time:
        enabled: true
  otlp:
    protocols:
      grpc: {endpoint: 0.0.0.0:4317}
      http: {endpoint: 0.0.0.0:4318}
processors:
  batch: {}
  resourcedetection:
    detectors: [system, env, azure]
    override: false
  resource/host:
    attributes:
      - {key: deployment.environment, value: demo-o11y-lamp, action: upsert}
exporters:
  signalfx:
    access_token: "\${SPLUNK_ACCESS_TOKEN}"
    realm: "\${SPLUNK_REALM}"
    sync_host_metadata: true
  otlphttp/traces:
    traces_endpoint: "https://ingest.\${SPLUNK_REALM}.signalfx.com/v2/trace/otlp"
    headers:
      X-SF-Token: "\${SPLUNK_ACCESS_TOKEN}"
service:
  extensions: [health_check]
  pipelines:
    metrics:
      receivers: [hostmetrics, mysql]
      processors: [resourcedetection, resource/host, batch]
      exporters: [signalfx]
    traces:
      receivers: [otlp]
      processors: [resourcedetection, resource/host, batch]
      exporters: [otlphttp/traces]
EOF
)

echo "==> Pushing web collector config to $WEB_IP"
push "$WEB_IP" "$WEB_CFG"
echo
echo "==> Pushing db collector config to $DB_IP"
push "$DB_IP"  "$DB_CFG"

echo
echo "==> Grant otel user PERFORMANCE_SCHEMA + extra privileges needed for new metrics"
ssh -o StrictHostKeyChecking=no "$USR@$DB_IP" "sudo mysql -e \"GRANT SELECT ON performance_schema.* TO 'otel'@'localhost'; FLUSH PRIVILEGES;\""

echo
echo "==> Generating PHP traffic on $WEB_IP"
for i in {1..60}; do curl -s -o /dev/null -X POST -d "name=tracegen$i&email=t$i@x.com&message=trace$i" "http://$WEB_IP/" & done
wait
echo "Done. Wait ~60s then check Splunk APM service 'php-lamp-demo'."
