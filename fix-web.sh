# Runs as root via remediate.sh; env: SPLUNK_REALM, SPLUNK_ACCESS_TOKEN, APP_PWD, OTEL_PWD
# Assumes Apache + PHP + mysql-client already installed by cloud-init.

PHP_VER=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
echo "[web-vm] PHP $PHP_VER detected"

echo "[web-vm] install collector"
curl -sSL https://dl.signalfx.com/splunk-otel-collector.sh -o /tmp/otel.sh
sh /tmp/otel.sh \
  --realm "$SPLUNK_REALM" \
  --mode agent \
  --without-instrumentation \
  "$SPLUNK_ACCESS_TOKEN" || echo "[web-vm] installer auto-start may have failed; continuing"
systemctl stop splunk-otel-collector || true

cat > /etc/otel/collector/custom-config.yaml <<EOF
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
  otlphttp:
    endpoint: "https://ingest.\${SPLUNK_REALM}.signalfx.com"
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
      exporters: [otlphttp]
EOF

CONF=/etc/otel/collector/splunk-otel-collector.conf
if grep -q '^SPLUNK_CONFIG=' "$CONF"; then
  sed -i 's|^SPLUNK_CONFIG=.*|SPLUNK_CONFIG=/etc/otel/collector/custom-config.yaml|' "$CONF"
else
  echo 'SPLUNK_CONFIG=/etc/otel/collector/custom-config.yaml' >> "$CONF"
fi
systemctl restart splunk-otel-collector

echo "[web-vm] enable apache mod_status (already in cloud-init, ensure)"
a2enmod status || true
a2enconf servername app-env || true
systemctl restart apache2

echo "[web-vm] install PHP OpenTelemetry (pecl + composer)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y \
  "php${PHP_VER}-dev" "php${PHP_VER}-cli" "php${PHP_VER}-mysql" "php${PHP_VER}-xml" \
  "php${PHP_VER}-mbstring" "php${PHP_VER}-curl" \
  php-pear gcc make autoconf pkg-config unzip git curl

# Install opentelemetry PECL extension (non-interactive: empty enable_zts)
printf "\n" | pecl install opentelemetry || pecl upgrade opentelemetry || true

EXT_DIR=$(php -r 'echo ini_get("extension_dir");')
if [ -f "$EXT_DIR/opentelemetry.so" ]; then
  echo "extension=opentelemetry.so" > "/etc/php/${PHP_VER}/mods-available/opentelemetry.ini"
  phpenmod -v "$PHP_VER" opentelemetry
  echo "[web-vm] PECL opentelemetry installed in $EXT_DIR"
else
  echo "[web-vm] WARNING: opentelemetry.so not found in $EXT_DIR"
fi

# Install composer
if ! command -v composer >/dev/null; then
  curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
fi

# Install OTel SDK + exporter + PDO auto-instrumentation in /var/www/html
cd /var/www/html
cat > composer.json <<'JSON'
{
  "require": {
    "open-telemetry/sdk": "^1.0",
    "open-telemetry/exporter-otlp": "^1.0",
    "open-telemetry/opentelemetry-auto-pdo": "^0.0.18 || ^0.1",
    "open-telemetry/opentelemetry-auto-slim": "^1.0",
    "php-http/guzzle7-adapter": "^1.0",
    "guzzlehttp/guzzle": "^7.0"
  },
  "config": {
    "allow-plugins": {
      "php-http/discovery": true
    }
  }
}
JSON
chown -R www-data:www-data /var/www/html
sudo -u www-data composer install --no-interaction --prefer-dist 2>&1 | tail -20 || true

# Auto-prepend file to bootstrap OTel on every request
cat > /var/www/html/_otel_bootstrap.php <<'PHP'
<?php
if (file_exists(__DIR__.'/vendor/autoload.php')) {
    require_once __DIR__.'/vendor/autoload.php';
}
PHP
chown www-data:www-data /var/www/html/_otel_bootstrap.php

# Apache env: service name + OTLP endpoint + auto_prepend_file
cat > /etc/apache2/conf-available/splunk-otel-env.conf <<EOF
SetEnv OTEL_PHP_AUTOLOAD_ENABLED true
SetEnv OTEL_SERVICE_NAME php-lamp-demo
SetEnv OTEL_RESOURCE_ATTRIBUTES deployment.environment=demo-o11y-lamp,service.version=1.0.0
SetEnv OTEL_TRACES_EXPORTER otlp
SetEnv OTEL_METRICS_EXPORTER otlp
SetEnv OTEL_LOGS_EXPORTER otlp
SetEnv OTEL_EXPORTER_OTLP_PROTOCOL http/protobuf
SetEnv OTEL_EXPORTER_OTLP_ENDPOINT http://127.0.0.1:4318
SetEnv OTEL_PROPAGATORS baggage,tracecontext
EOF

# auto_prepend_file in php.ini (Apache SAPI) so the SDK is loaded for /var/www/html/*
cat > "/etc/php/${PHP_VER}/apache2/conf.d/99-otel.ini" <<EOF
auto_prepend_file = /var/www/html/_otel_bootstrap.php
EOF

a2enconf splunk-otel-env
systemctl restart apache2

echo "[web-vm] verify"
php -m | grep -i opentelemetry || echo "WARN: opentelemetry not loaded in CLI"
systemctl is-active splunk-otel-collector || true
curl -s http://127.0.0.1:13133/ && echo
echo "[web-vm] done"
