# PHP OpenTelemetry Instrumentation (Splunk APM)

End-to-end recipe for instrumenting a plain **PHP 8.3 + Apache (mod_php / prefork)**
application on Ubuntu 24.04 so spans land in **Splunk Observability Cloud → APM**.

> This is what runs on `vm-web` in this project. Service shown in APM:
> `php-lamp-demo`, environment `demo-o11y-lamp`.

---

## 1. Prerequisites

### 1.1 OS / runtime packages

| Component | Version used here | Notes |
|---|---|---|
| Ubuntu | 24.04 LTS | `php-pear`, `php-dev`, build-essential needed to build the PECL extension |
| PHP | 8.3 (Ubuntu default) | mod_php under Apache (`libapache2-mod-php`) |
| Apache | 2.4.x | prefork MPM is the default with mod_php |
| Composer | 2.x | installed via `getcomposer.org` installer |
| Splunk OTel Collector | ≥ v0.119 (we run v0.152) | provides the OTLP/HTTP receiver on `:4318` |

Apt install line used (see [fix-web.sh](../fix-web.sh)):

```bash
apt-get install -y \
  apache2 libapache2-mod-php php-cli php-mysql php-curl php-mbstring \
  php-xml php-zip php-dev php-pear build-essential pkg-config \
  autoconf gcc make
```

### 1.2 PHP extension: `opentelemetry` (PECL)

The SDK alone is not enough — it requires the C extension to hook into the Zend
engine and intercept function calls (this is what enables every auto-instrumentation
package, including `auto-pdo`).

```bash
pecl channel-update pecl.php.net
pecl install opentelemetry
echo "extension=opentelemetry.so" | sudo tee /etc/php/8.3/mods-available/opentelemetry.ini
sudo phpenmod -v 8.3 -s ALL opentelemetry      # enables for cli AND apache2 SAPI
sudo systemctl restart apache2
php -m | grep opentelemetry                    # must list "opentelemetry"
```

> Pitfall: PECL installs the `.so` into the PHP API directory
> (e.g. `/usr/lib/php/20230831/opentelemetry.so`). If you only edit
> `php.ini` you'll enable it for CLI but **not for Apache** — always use
> `phpenmod` which symlinks into both `cli/conf.d/` and `apache2/conf.d/`.

### 1.3 Composer SDK + auto-instrumentation

In your app's web root (`/var/www/html`):

```bash
composer require \
  open-telemetry/sdk \
  open-telemetry/exporter-otlp \
  open-telemetry/opentelemetry-auto-pdo \
  open-telemetry/opentelemetry-auto-slim     # only useful if you use Slim
```

| Package | Purpose |
|---|---|
| `open-telemetry/sdk` | The TracerProvider / SpanProcessor / context propagation |
| `open-telemetry/exporter-otlp` | Sends spans over OTLP/HTTP to the local collector |
| `opentelemetry-auto-pdo` | Wraps every PDO statement → DB child spans |
| `opentelemetry-auto-slim` | Only fires if you use the Slim micro-framework |

> Plain PHP + Apache has **no community auto-instrumentation for the incoming
> HTTP request itself**. You must create the root span yourself — see step 3.

### 1.4 Local collector (OTLP receiver)

The PHP SDK ships spans to `http://127.0.0.1:4318/v1/traces`, so the collector
must expose the OTLP/HTTP receiver:

```yaml
receivers:
  otlp:
    protocols:
      http: { endpoint: 0.0.0.0:4318 }
exporters:
  otlphttp/traces:
    traces_endpoint: "https://ingest.${SPLUNK_REALM}.signalfx.com/v2/trace/otlp"
    headers:
      X-SF-Token: "${SPLUNK_ACCESS_TOKEN}"
service:
  pipelines:
    traces:
      receivers:  [otlp]
      processors: [resourcedetection, resource/normalize_host, batch]
      exporters:  [otlphttp/traces]
```

**Critical:** the Splunk APM trace ingest path is `/v2/trace/otlp` — *not* the
root signalfx ingest URL. Wrong endpoint = 404/200-but-discarded and spans never
appear in APM.

### 1.5 APM ↔ Infrastructure correlation

Splunk correlates a trace with its host card via **exact `host.name` match**.
- The PHP SDK's `host` detector emits the *short* hostname (`vm-web`).
- The Azure resource detector in the collector emits the *internal FQDN*
  (`vm-web.<vmss-zone>.internal.cloudapp.net`).

If they differ, the "Related Content → Infrastructure" link is dead. Fix it with
a `resource` processor that overwrites `host.name` from `azure.vm.name`
(applied in [fix-apm-infra-correlation.sh](../fix-apm-infra-correlation.sh)):

```yaml
processors:
  resource/normalize_host:
    attributes:
      - { key: host.name, from_attribute: azure.vm.name, action: upsert }
```

Insert it in **both** `metrics` and `traces` pipelines, right after `resourcedetection`.

---

## 2. Apache environment for OpenTelemetry

The SDK is configured entirely through env vars. With `mod_php` they must be
passed to the FastCGI/Apache SAPI via `SetEnv`. Create
`/etc/apache2/conf-available/splunk-otel-env.conf`:

```apache
# Apache → mod_php environment for OpenTelemetry
SetEnv OTEL_PHP_AUTOLOAD_ENABLED            true
SetEnv OTEL_SERVICE_NAME                    php-lamp-demo
SetEnv OTEL_RESOURCE_ATTRIBUTES             deployment.environment=demo-o11y-lamp,service.version=1.0.0
SetEnv OTEL_TRACES_EXPORTER                 otlp
SetEnv OTEL_METRICS_EXPORTER                none
SetEnv OTEL_LOGS_EXPORTER                   none
SetEnv OTEL_EXPORTER_OTLP_PROTOCOL          http/protobuf
SetEnv OTEL_EXPORTER_OTLP_ENDPOINT          http://127.0.0.1:4318
SetEnv OTEL_PROPAGATORS                     baggage,tracecontext
```

Enable and reload:

```bash
sudo a2enconf splunk-otel-env
sudo systemctl reload apache2
```

> `OTEL_PHP_AUTOLOAD_ENABLED=true` is what makes the Composer-installed
> auto-instrumentation packages register themselves as soon as
> `vendor/autoload.php` is required.

---

## 3. Bootstrap file (`auto_prepend_file`)

Plain PHP+Apache has no framework-level request wrapper, so:

1. Load Composer's autoload (which triggers the auto-instrumentation registration).
2. Open a **SERVER** root span manually so PDO/HTTP child spans have a parent.

`/var/www/html/_otel_bootstrap.php` (full content in [fix-php-root-span.sh](../fix-php-root-span.sh)):

```php
<?php
require_once '/var/www/html/vendor/autoload.php';
if (PHP_SAPI === 'cli') { return; }

use OpenTelemetry\API\Globals;
use OpenTelemetry\API\Trace\SpanKind;
use OpenTelemetry\API\Trace\StatusCode;

$tracer = Globals::tracerProvider()->getTracer('php.apache.request');
$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';
$route  = strtok($_SERVER['REQUEST_URI'] ?? '/', '?');

$span = $tracer->spanBuilder("$method $route")
    ->setSpanKind(SpanKind::KIND_SERVER)
    ->startSpan();
$span->setAttribute('http.request.method', $method);
$span->setAttribute('url.path',            $_SERVER['REQUEST_URI'] ?? '/');
$span->setAttribute('url.scheme',          empty($_SERVER['HTTPS']) ? 'http' : 'https');
$span->setAttribute('server.address',      $_SERVER['HTTP_HOST']   ?? '');
$span->setAttribute('client.address',      $_SERVER['REMOTE_ADDR'] ?? '');
$scope = $span->activate();

register_shutdown_function(static function () use ($span, $scope) {
    $code = http_response_code() ?: 200;
    $span->setAttribute('http.response.status_code', $code);
    if ($code >= 500) { $span->setStatus(StatusCode::STATUS_ERROR); }
    $scope->detach();
    $span->end();
});
```

Wire it as `auto_prepend_file` (`/etc/php/8.3/apache2/conf.d/99-otel.ini`):

```ini
auto_prepend_file = /var/www/html/_otel_bootstrap.php
```

`sudo systemctl reload apache2` — done. Every request is now a span; PDO calls
inside it become child spans automatically.

---

## 4. Verification cheat-sheet

```bash
# 1. Extension loaded in the *Apache* SAPI (not just CLI)
sudo apache2ctl -t -D DUMP_MODULES | grep php
php -d auto_prepend_file=/var/www/html/_otel_bootstrap.php -r 'echo PHP_VERSION;'
ls -l /etc/php/8.3/apache2/conf.d/ | grep -E 'opentelemetry|otel'

# 2. Spans accepted by collector and successfully exported to Splunk
curl -s http://127.0.0.1:8888/metrics | grep -E 'otelcol_(receiver_accepted|exporter_sent)_spans'

# 3. End-to-end smoke test
curl -X POST -d 'name=t&email=t@x.io&message=hi' http://<web-vm-public-ip>/
sleep 10
# Then look in Splunk APM > Services > php-lamp-demo
```

Healthy state looks like (after a few requests):

```
otelcol_receiver_accepted_spans{receiver="otlp",transport="http"}                                 135
otelcol_exporter_sent_spans{exporter="otlphttp/traces",url_path="/v2/trace/otlp"}                 135
# zero entries for otelcol_exporter_send_failed_spans
```

---

## 5. Common pitfalls (debugging checklist)

| Symptom | Likely cause | Fix |
|---|---|---|
| `php -m` shows `opentelemetry` but Apache doesn't | `.so` only enabled for CLI | `sudo phpenmod -v 8.3 -s ALL opentelemetry` + restart Apache |
| Collector logs "spans" = 0 | Bootstrap not loaded | Verify `auto_prepend_file` is in **apache2** conf.d, not cli |
| Spans reach collector but not Splunk APM | Wrong trace endpoint | Use `https://ingest.<realm>.signalfx.com/v2/trace/otlp` + `X-SF-Token` header |
| Only PDO spans, no parent server span | Missing manual root span | Implement step 3 (`_otel_bootstrap.php`) |
| APM Service page works, "Related Content > Infrastructure" empty | `host.name` mismatch (FQDN vs short) | `resource/normalize_host` processor (§1.5) |
| Spans tagged `service.name=unknown_service:php` | `OTEL_SERVICE_NAME` not in Apache env | Use `SetEnv` in Apache conf; verify with `phpinfo()` "Environment" |
| App slow after enabling | `BatchSpanProcessor` blocked on slow exporter | Confirm collector reachable on `127.0.0.1:4318` |

---

## 6. References

- [Splunk: instrument PHP with OpenTelemetry](https://docs.splunk.com/observability/en/gdi/get-data-in/application/php/get-started.html)
- [OpenTelemetry PHP contrib auto-instrumentation list](https://github.com/open-telemetry/opentelemetry-php-contrib)
- [Splunk OpenTelemetry Collector configuration reference](https://github.com/signalfx/splunk-otel-collector)

---

## 7. Manual installation — step-by-step

This is exactly what [fix-web.sh](../fix-web.sh) + [fix-php-root-span.sh](../fix-php-root-span.sh)
did on `vm-web`, broken into manual commands you can run yourself.

> Run all commands as a sudoer on the LAMP VM (Ubuntu 24.04, PHP 8.3,
> Apache prefork + mod_php).

### 7.0 Variables you'll reuse

```bash
export SPLUNK_REALM="eu1"
export SPLUNK_ACCESS_TOKEN="<your-token>"
export SERVICE_NAME="php-lamp-demo"
export DEPLOY_ENV="demo-o11y-lamp"
```

### 7.1 Install build prerequisites for the PECL extension

The OTel SDK alone is not enough; it needs a native PHP extension to hook the
Zend engine.

```bash
sudo apt-get update
sudo apt-get install -y \
  php-cli php-dev php-pear php-mysql php-curl php-mbstring php-xml php-zip \
  build-essential pkg-config autoconf gcc make unzip curl
```

### 7.2 Install the Splunk OTel Collector (local OTLP receiver)

The PHP SDK ships spans to `127.0.0.1:4318`; the collector forwards them to
Splunk APM.

```bash
curl -sSL https://dl.signalfx.com/splunk-otel-collector.sh > /tmp/splunk-otel-collector.sh
sudo sh /tmp/splunk-otel-collector.sh \
  --realm "$SPLUNK_REALM" \
  --mode agent \
  --collector-config /etc/otel/collector/custom-config.yaml \
  -- "$SPLUNK_ACCESS_TOKEN" || true
sudo systemctl stop splunk-otel-collector
```

(The installer auto-starts the service; we stop it because we'll write our own
config in step 7.6.)

### 7.3 Install the PECL `opentelemetry` extension

```bash
sudo pecl channel-update pecl.php.net
printf "\n" | sudo pecl install opentelemetry          # accept defaults
echo "extension=opentelemetry.so" | sudo tee /etc/php/8.3/mods-available/opentelemetry.ini
sudo phpenmod -v 8.3 -s ALL opentelemetry              # enable for BOTH cli and apache2 SAPI
sudo systemctl reload apache2

# Verify
php -m | grep opentelemetry
sudo -u www-data php -r 'echo extension_loaded("opentelemetry") ? "OK\n" : "MISSING\n";'
```

> **Pitfall:** if you only edit `php.ini` you'll enable it for CLI but **not**
> Apache. Always use `phpenmod`.

### 7.4 Install Composer + the OpenTelemetry SDK in the web root

```bash
# Composer
curl -sS https://getcomposer.org/installer | sudo php -- --install-dir=/usr/local/bin --filename=composer

# SDK + auto-instrumentation packages
cd /var/www/html
sudo composer require --no-interaction \
  open-telemetry/sdk \
  open-telemetry/exporter-otlp \
  open-telemetry/opentelemetry-auto-pdo \
  open-telemetry/opentelemetry-auto-slim
sudo chown -R www-data:www-data /var/www/html/vendor /var/www/html/composer.*
```

What each package does:

| Package | Purpose |
|---|---|
| `open-telemetry/sdk` | TracerProvider, span processor, context propagation |
| `open-telemetry/exporter-otlp` | Sends spans to local collector over OTLP/HTTP |
| `opentelemetry-auto-pdo` | Wraps every PDO call as a child DB span |
| `opentelemetry-auto-slim` | Only useful if you're using the Slim framework |

### 7.5 Bootstrap file + Apache env vars

#### 7.5a Root-span bootstrap (`/var/www/html/_otel_bootstrap.php`)

Plain PHP+Apache has no community auto-instrumentation for incoming HTTP
requests — you must create the SERVER root span yourself.

```bash
sudo tee /var/www/html/_otel_bootstrap.php >/dev/null <<'PHP'
<?php
require_once '/var/www/html/vendor/autoload.php';
if (PHP_SAPI === 'cli') { return; }

use OpenTelemetry\API\Globals;
use OpenTelemetry\API\Trace\SpanKind;
use OpenTelemetry\API\Trace\StatusCode;

try {
    $tracer = Globals::tracerProvider()->getTracer('php.apache.request');
    $method = $_SERVER['REQUEST_METHOD'] ?? 'GET';
    $route  = strtok($_SERVER['REQUEST_URI'] ?? '/', '?');

    $span = $tracer->spanBuilder("$method $route")
        ->setSpanKind(SpanKind::KIND_SERVER)
        ->startSpan();
    $span->setAttribute('http.request.method', $method);
    $span->setAttribute('url.path',            $_SERVER['REQUEST_URI'] ?? '/');
    $span->setAttribute('url.scheme',          empty($_SERVER['HTTPS']) ? 'http' : 'https');
    $span->setAttribute('server.address',      $_SERVER['HTTP_HOST']   ?? '');
    $span->setAttribute('client.address',      $_SERVER['REMOTE_ADDR'] ?? '');
    $scope = $span->activate();

    register_shutdown_function(static function () use ($span, $scope) {
        $code = http_response_code() ?: 200;
        $span->setAttribute('http.response.status_code', $code);
        if ($code >= 500) { $span->setStatus(StatusCode::STATUS_ERROR); }
        $scope->detach();
        $span->end();
    });
} catch (\Throwable $e) { error_log('[otel-bootstrap] '.$e->getMessage()); }
PHP
sudo chmod 644 /var/www/html/_otel_bootstrap.php
```

#### 7.5b Wire it as `auto_prepend_file` for the Apache SAPI

```bash
sudo tee /etc/php/8.3/apache2/conf.d/99-otel.ini >/dev/null <<'INI'
auto_prepend_file = /var/www/html/_otel_bootstrap.php
INI
```

#### 7.5c Pass OTEL_* env vars to mod_php via Apache `SetEnv`

```bash
sudo tee /etc/apache2/conf-available/splunk-otel-env.conf >/dev/null <<EOF
SetEnv OTEL_PHP_AUTOLOAD_ENABLED   true
SetEnv OTEL_SERVICE_NAME           ${SERVICE_NAME}
SetEnv OTEL_RESOURCE_ATTRIBUTES    deployment.environment=${DEPLOY_ENV},service.version=1.0.0
SetEnv OTEL_TRACES_EXPORTER        otlp
SetEnv OTEL_METRICS_EXPORTER       none
SetEnv OTEL_LOGS_EXPORTER          none
SetEnv OTEL_EXPORTER_OTLP_PROTOCOL http/protobuf
SetEnv OTEL_EXPORTER_OTLP_ENDPOINT http://127.0.0.1:4318
SetEnv OTEL_PROPAGATORS            baggage,tracecontext
EOF

sudo a2enconf splunk-otel-env
sudo systemctl reload apache2
```

> **Critical:** `OTEL_PHP_AUTOLOAD_ENABLED=true` is what makes auto-pdo
> register itself the moment `vendor/autoload.php` is loaded.

### 7.6 Collector config (OTLP receiver → Splunk APM)

```bash
sudo tee /etc/otel/collector/custom-config.yaml >/dev/null <<EOF
extensions:
  health_check: { endpoint: 0.0.0.0:13133 }

receivers:
  otlp:
    protocols:
      grpc: { endpoint: 0.0.0.0:4317 }
      http: { endpoint: 0.0.0.0:4318 }
  hostmetrics:
    collection_interval: 30s
    scrapers: { cpu: {}, disk: {}, filesystem: {}, load: {}, memory: {}, network: {}, paging: {}, processes: {} }
  apache:
    endpoint: http://localhost:80/server-status?auto
    collection_interval: 30s

processors:
  batch: {}
  resourcedetection:
    detectors: [system, env, azure]
    override: false
  # Force host.name to the short Azure VM name so APM<->Infra correlation works.
  resource/normalize_host:
    attributes:
      - { key: host.name, from_attribute: azure.vm.name, action: upsert }
  resource/host:
    attributes:
      - { key: deployment.environment, value: ${DEPLOY_ENV}, action: upsert }

exporters:
  signalfx:
    access_token: "\${SPLUNK_ACCESS_TOKEN}"
    realm:        "\${SPLUNK_REALM}"
    sync_host_metadata: true
  # Splunk APM trace ingest path — NOT the root signalfx URL!
  otlphttp/traces:
    traces_endpoint: "https://ingest.\${SPLUNK_REALM}.signalfx.com/v2/trace/otlp"
    headers:
      X-SF-Token: "\${SPLUNK_ACCESS_TOKEN}"

service:
  extensions: [health_check]
  pipelines:
    metrics:
      receivers:  [hostmetrics, apache]
      processors: [resourcedetection, resource/normalize_host, resource/host, batch]
      exporters:  [signalfx]
    traces:
      receivers:  [otlp]
      processors: [resourcedetection, resource/normalize_host, resource/host, batch]
      exporters:  [otlphttp/traces]
EOF

# Ensure realm + token are in the service env file
sudo sed -i \
  -e "s|^SPLUNK_REALM=.*|SPLUNK_REALM=${SPLUNK_REALM}|" \
  -e "s|^SPLUNK_ACCESS_TOKEN=.*|SPLUNK_ACCESS_TOKEN=${SPLUNK_ACCESS_TOKEN}|" \
  /etc/otel/collector/splunk-otel-collector.conf

sudo systemctl restart splunk-otel-collector
sudo systemctl status splunk-otel-collector --no-pager | head -6
```

### 7.7 Smoke test

```bash
# Make a request
curl -X POST -d "name=Test&email=t@x.io&message=hi" http://127.0.0.1/

# Collector internal counters — both numbers should be equal and > 0
curl -s http://127.0.0.1:8888/metrics | grep -E 'otelcol_(receiver_accepted|exporter_sent)_spans'

# Health check
curl -s http://127.0.0.1:13133/ ; echo

# Should be no failures
curl -s http://127.0.0.1:8888/metrics | grep exporter_send_failed_spans || echo "no failures"
```

Healthy output:

```
otelcol_receiver_accepted_spans{receiver="otlp",transport="http"}                                 6
otelcol_exporter_sent_spans{exporter="otlphttp/traces",url_path="/v2/trace/otlp"}                 6
{"status":"Server available"}
no failures
```

Then in **Splunk Observability → APM → Services**, look for `php-lamp-demo`
(env `demo-o11y-lamp`) — spans appear within ~30 s.

### 7.8 What each step accomplishes

| Step | What it produces |
|---|---|
| 7.1 | Compiler + headers so PECL can build a native PHP extension |
| 7.2 | Local OTel agent listening on `:4318` (OTLP/HTTP) and `:8888` (Prometheus self-metrics) |
| 7.3 | `opentelemetry.so` loaded in **both** CLI and Apache SAPIs — the hook engine |
| 7.4 | SDK + auto-PDO instrumentation available to PHP via Composer autoload |
| 7.5 | Every Apache request: env vars set → bootstrap runs → SERVER span created → PDO calls become child spans → span flushed on shutdown |
| 7.6 | Collector forwards spans to Splunk APM `/v2/trace/otlp` and normalizes `host.name` so APM-Infra correlation works |
| 7.7 | End-to-end verified by lockstep counter increments |

If anything fails, jump back to §5 *Common pitfalls*.
