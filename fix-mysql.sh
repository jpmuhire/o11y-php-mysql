# Runs as root via remediate.sh; env: SPLUNK_REALM, SPLUNK_ACCESS_TOKEN, APP_PWD, OTEL_PWD

echo "[mysql-vm] install collector"
curl -sSL https://dl.signalfx.com/splunk-otel-collector.sh -o /tmp/otel.sh
sh /tmp/otel.sh \
  --realm "$SPLUNK_REALM" \
  --mode agent \
  --without-instrumentation \
  "$SPLUNK_ACCESS_TOKEN" || echo "[mysql-vm] installer auto-start may have failed; continuing"
systemctl stop splunk-otel-collector || true

echo "[mysql-vm] ensure DB + users"
systemctl enable --now mysql
cat > /tmp/init-db.sql <<SQL
CREATE DATABASE IF NOT EXISTS appdb CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'appuser'@'%' IDENTIFIED BY '$APP_PWD';
ALTER USER 'appuser'@'%' IDENTIFIED BY '$APP_PWD';
GRANT ALL PRIVILEGES ON appdb.* TO 'appuser'@'%';
CREATE USER IF NOT EXISTS 'otel'@'localhost' IDENTIFIED BY '$OTEL_PWD';
ALTER USER 'otel'@'localhost' IDENTIFIED BY '$OTEL_PWD';
GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'otel'@'localhost';
USE appdb;
CREATE TABLE IF NOT EXISTS entries (
  id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(120) NOT NULL,
  email VARCHAR(180),
  message TEXT,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
FLUSH PRIVILEGES;
SQL
mysql < /tmp/init-db.sql
rm -f /tmp/init-db.sql

# Bind MySQL to 0.0.0.0 so the web VM can connect over the VNet
# (Ubuntu's default mysqld.cnf has bind-address=127.0.0.1 and wins over 99-*.cnf)
sed -i 's|^bind-address.*= 127.0.0.1|bind-address            = 0.0.0.0|' /etc/mysql/mysql.conf.d/mysqld.cnf
cat > /etc/mysql/mysql.conf.d/99-listen.cnf <<'CFG'
[mysqld]
bind-address = 0.0.0.0
mysqlx-bind-address = 127.0.0.1
CFG
systemctl restart mysql

echo "[mysql-vm] write collector config"
cat > /etc/otel/collector/custom-config.yaml <<EOF
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
  otlphttp:
    endpoint: "https://ingest.\${SPLUNK_REALM}.signalfx.com"
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
      exporters: [otlphttp]
EOF

# Point the collector at our custom config
CONF=/etc/otel/collector/splunk-otel-collector.conf
if grep -q '^SPLUNK_CONFIG=' "$CONF"; then
  sed -i 's|^SPLUNK_CONFIG=.*|SPLUNK_CONFIG=/etc/otel/collector/custom-config.yaml|' "$CONF"
else
  echo 'SPLUNK_CONFIG=/etc/otel/collector/custom-config.yaml' >> "$CONF"
fi
systemctl restart splunk-otel-collector
sleep 3
systemctl is-active splunk-otel-collector || true
journalctl -u splunk-otel-collector -n 30 --no-pager || true
echo "[mysql-vm] done"
