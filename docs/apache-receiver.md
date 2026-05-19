# Apache Receiver (`apachereceiver`)

Scrapes Apache HTTPD's `mod_status` page and emits metrics about workers,
requests, traffic and CPU load.

> Runs on `vm-web` in this project alongside the PHP/OTel instrumentation.
> Component reference: [`apachereceiver`](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/receiver/apachereceiver).

---

## 1. Prerequisites

### 1.1 Apache module `mod_status` enabled

`mod_status` exposes a machine-readable text endpoint (`?auto`) the receiver
parses. It is **not enabled by default** on Ubuntu/Debian.

```bash
sudo a2enmod status
sudo systemctl reload apache2
```

Verify the module is loaded:

```bash
sudo apache2ctl -M | grep status
# status_module (shared)
```

### 1.2 `ExtendedStatus On` (required)

Without extended status, per-worker CPU and request times are absent and the
receiver reports a partial set of metrics. On Apache 2.4 this is **on by default
whenever `mod_status` is loaded**, but if a distro template disables it, force it:

```apache
# /etc/apache2/conf-available/status.conf  (Ubuntu default file)
ExtendedStatus On
```

### 1.3 `server-status` endpoint reachable from the collector

The receiver fetches `http://<host>:<port>/server-status?auto`. The default
Ubuntu config restricts it to `127.0.0.1` — perfect for a co-located collector.
If you ever move the collector to a different host, widen the `<Location>` block
and/or expose a private port.

Default Ubuntu config (`/etc/apache2/mods-available/status.conf`):

```apache
<Location /server-status>
    SetHandler server-status
    Require local
</Location>
```

Smoke test from the collector host:

```bash
curl -s 'http://localhost:80/server-status?auto' | head
# Total Accesses: 4321
# Total kBytes: 12345
# CPULoad: .00012
# Uptime: 600
# ReqPerSec: 7.2
# BusyWorkers: 1
# IdleWorkers: 24
```

If you get HTML instead of `key: value\n` lines, you forgot `?auto`. If you get
`403`, `Require local` is blocking you — the receiver must run on the same host
or the directive must be relaxed.

### 1.4 No auth needed (and none supported in a simple way)

`mod_status` typically runs without auth on `127.0.0.1`. If you protect it with
HTTP Basic, the receiver does not support credentials directly — front it with a
local reverse proxy or unprotect it on the loopback interface.

### 1.5 Splunk OTel Collector includes this receiver out of the box

The official Splunk distro bundles `apachereceiver`. No extra image / build is
required.

---

## 2. Collector configuration

Minimal block used on `vm-web` (full config: [collector-web.yaml](../collector-web.yaml)):

```yaml
receivers:
  apache:
    endpoint: http://localhost:80/server-status?auto
    collection_interval: 30s

processors:
  resourcedetection:
    detectors: [system, env, azure]
    override: false
  resource/normalize_host:
    attributes:
      - { key: host.name, from_attribute: azure.vm.name, action: upsert }
  batch: {}

exporters:
  signalfx:
    access_token: "${SPLUNK_ACCESS_TOKEN}"
    realm:        "${SPLUNK_REALM}"
    sync_host_metadata: true

service:
  pipelines:
    metrics:
      receivers:  [apache, hostmetrics]
      processors: [resourcedetection, resource/normalize_host, batch]
      exporters:  [signalfx]
```

### Optional metrics

Several metrics are emitted by default; a few are opt-in. Enable them under the
receiver's `metrics:` block, e.g.:

```yaml
receivers:
  apache:
    endpoint: http://localhost:80/server-status?auto
    collection_interval: 30s
    metrics:
      apache.cpu.time:            { enabled: true }
      apache.cpu.load:            { enabled: true }
      apache.load.1:              { enabled: true }
      apache.load.5:              { enabled: true }
      apache.load.15:             { enabled: true }
      apache.request.time:        { enabled: true }
```

Full list and default-enabled flags: see [metadata.yaml](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/receiver/apachereceiver/metadata.yaml).

---

## 3. Metrics produced

| Metric | Unit | Default | Description |
|---|---|---|---|
| `apache.uptime` | s | ✓ | Server uptime |
| `apache.current_connections` | {connections} | ✓ | Active connections being served |
| `apache.workers` | {workers} | ✓ | Workers (state=`busy`/`idle`) |
| `apache.requests` | {requests} | ✓ | Total requests served (counter) |
| `apache.traffic` | by | ✓ | Total bytes served (counter) |
| `apache.scoreboard` | {workers} | ✓ | Workers per scoreboard state (waiting, reading, sending, …) |
| `apache.cpu.time` | s | opt-in | CPU time per worker type |
| `apache.cpu.load` | % | opt-in | CPU load reported by `mod_status` |
| `apache.load.1` / `.5` / `.15` | — | opt-in | Apache-reported load averages |
| `apache.request.time` | ms | opt-in | Avg time per request |

Resource attributes attached: `apache.server.name`, `apache.server.port`, plus
everything `resourcedetection` adds (`host.name`, `azure.vm.name`, `cloud.*`).

---

## 4. Verification

```bash
# 1. Endpoint reachable
curl -fsS 'http://localhost:80/server-status?auto' >/dev/null && echo OK

# 2. Receiver pulling
curl -s http://127.0.0.1:8888/metrics | grep apache
# otelcol_receiver_accepted_metric_points{receiver="apache",transport=""} 250

# 3. Metrics in Splunk (Metric Finder)
#    apache.requests, apache.workers, apache.traffic, apache.scoreboard
```

Then in Splunk Observability → **Infrastructure → Apache** built-in
navigator should automatically pick up the host once `host.name` matches.

---

## 5. Common pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| `403 Forbidden` on `/server-status` | `Require local` and collector is remote | Run collector on same host or widen the `<Location>` |
| HTML returned instead of `key: value` lines | Forgot `?auto` query string | Use the exact URL above |
| Only a few metrics show up | `ExtendedStatus Off` | Set `ExtendedStatus On` in `status.conf` |
| `apachereceiver` errors `connection refused` | Apache bound only on a specific IP | Endpoint hostname must match `Listen` directive |
| `host.name` mismatch breaks Infrastructure correlation | Azure detector emits FQDN, other sources emit short name | Use `resource/normalize_host` processor (see PHP doc §1.5) |
| Counters reset on Apache reload | Apache `mod_status` itself resets on graceful restart | Expected — Splunk handles counter resets correctly |

---

## 6. References

- Source: <https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/receiver/apachereceiver>
- Apache `mod_status` docs: <https://httpd.apache.org/docs/2.4/mod/mod_status.html>
- Splunk APM/Infra correlation: see [php-opentelemetry-instrumentation.md](./php-opentelemetry-instrumentation.md) §1.5
