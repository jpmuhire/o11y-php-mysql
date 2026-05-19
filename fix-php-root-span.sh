#!/usr/bin/env bash
# Adds an Apache/PHP root-span wrapper to _otel_bootstrap.php so each HTTP
# request produces a server span visible in Splunk APM. The existing PDO
# auto-instrumentation will become child spans of this root span.
set -euo pipefail

: "${SPLUNK_REALM:?}"
: "${SPLUNK_ACCESS_TOKEN:?}"

WEB_IP="${WEB_IP:-20.123.149.120}"
SSH_USER="${SSH_USER:-azureuser}"

BOOTSTRAP=$(cat <<'PHP'
<?php
// Splunk OTel bootstrap for plain PHP+Apache (auto_prepend_file)
require_once '/var/www/html/vendor/autoload.php';

// Skip CLI / non-web invocations
if (PHP_SAPI === 'cli') {
    return;
}

use OpenTelemetry\API\Globals;
use OpenTelemetry\API\Trace\SpanKind;
use OpenTelemetry\API\Trace\StatusCode;
use OpenTelemetry\Context\Context;

try {
    $tracer = Globals::tracerProvider()->getTracer('php.apache.request');

    $method = $_SERVER['REQUEST_METHOD'] ?? 'GET';
    $path   = $_SERVER['REQUEST_URI']    ?? '/';
    $route  = strtok($path, '?');

    $span = $tracer->spanBuilder(sprintf('%s %s', $method, $route))
        ->setSpanKind(SpanKind::KIND_SERVER)
        ->startSpan();

    $span->setAttribute('http.request.method', $method);
    $span->setAttribute('url.path', $path);
    $span->setAttribute('url.scheme', !empty($_SERVER['HTTPS']) ? 'https' : 'http');
    $span->setAttribute('server.address', $_SERVER['HTTP_HOST'] ?? '');
    $span->setAttribute('user_agent.original', $_SERVER['HTTP_USER_AGENT'] ?? '');
    $span->setAttribute('client.address', $_SERVER['REMOTE_ADDR'] ?? '');

    $scope = $span->activate();

    register_shutdown_function(static function () use ($span, $scope) {
        $code = http_response_code() ?: 200;
        $span->setAttribute('http.response.status_code', $code);
        if ($code >= 500) {
            $span->setStatus(StatusCode::STATUS_ERROR);
        }
        $err = error_get_last();
        if ($err !== null && in_array($err['type'], [E_ERROR, E_PARSE, E_CORE_ERROR, E_COMPILE_ERROR], true)) {
            $span->setStatus(StatusCode::STATUS_ERROR, $err['message']);
            $span->setAttribute('exception.message', $err['message']);
            $span->setAttribute('exception.type', 'PHPFatalError');
        }
        $scope->detach();
        $span->end();
    });
} catch (\Throwable $e) {
    // Never break the app because of telemetry
    error_log('[otel-bootstrap] ' . $e->getMessage());
}
PHP
)

echo "==> Pushing root-span bootstrap to ${WEB_IP}..."
ssh -o StrictHostKeyChecking=no "${SSH_USER}@${WEB_IP}" "sudo tee /var/www/html/_otel_bootstrap.php >/dev/null && sudo chmod 644 /var/www/html/_otel_bootstrap.php && sudo systemctl reload apache2" <<EOF
${BOOTSTRAP}
EOF

echo "==> Generating traffic..."
for i in $(seq 1 25); do
    curl -s -o /dev/null -X POST -d "name=Test${i}&email=t${i}@x.io&message=hi-${i}" "http://${WEB_IP}/" &
    curl -s -o /dev/null "http://${WEB_IP}/" &
done
wait

echo "==> Tailing collector logs for trace activity..."
ssh -o StrictHostKeyChecking=no "${SSH_USER}@${WEB_IP}" 'sleep 15 && sudo journalctl -u splunk-otel-collector --since "1 min ago" --no-pager | grep -iE "trace|span|otlphttp|export|error" | tail -30'

echo
echo "Done. Check Splunk APM for service 'php-lamp-demo' in environment 'demo-o11y-lamp'."
