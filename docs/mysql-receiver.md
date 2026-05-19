# MySQL Receiver (`mysqlreceiver`)

Scrapes a MySQL/MariaDB server over the native protocol using `SHOW GLOBAL
STATUS`, `INFORMATION_SCHEMA` and `performance_schema` queries.

> Runs on `vm-mysql` in this project, scraping the local MySQL 8.0 instance.
> Component reference:
> [`mysqlreceiver`](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/receiver/mysqlreceiver).

---

## 1. Prerequisites

### 1.1 MySQL server reachable from the collector

We co-locate the collector on the DB host, so the receiver connects to
`127.0.0.1:3306`. If you keep the collector on a different host, MySQL must:

- Be bound on a routable interface (`bind-address = 0.0.0.0` or a specific IP).
- Allow the user from that host (`'otel'@'collector-ip-or-subnet'`).

> Pitfall (hit on this project): Ubuntu's default
> `/etc/mysql/mysql.conf.d/mysqld.cnf` sets `bind-address = 127.0.0.1` and is
> read **after** any custom `99-*.cnf` (file order is alphabetical, last write
> wins). To listen on all interfaces edit `mysqld.cnf` directly — or use
> `mysqld --bind-address` override.

### 1.2 Monitoring user with the right grants

Create a least-privilege user for the collector:

```sql
CREATE USER IF NOT EXISTS 'otel'@'localhost' IDENTIFIED BY '<strong-random>';

-- Required for SHOW GLOBAL STATUS, replication, schema enumeration:
GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'otel'@'localhost';

-- Required for the InnoDB/optional metrics (locks, statement events, etc.):
GRANT SELECT ON performance_schema.* TO 'otel'@'localhost';

FLUSH PRIVILEGES;
```

For MySQL 5.7 the `SHOW VIEW` privilege may also be required for the
information_schema.tables scrape. On 8.0 `SELECT` is sufficient.

### 1.3 `performance_schema` enabled

Required for the opt-in statement-level metrics (slow queries, prepared
statements, table I/O, lock waits, etc.). MySQL 8.0 has it **on by default**:

```sql
SHOW VARIABLES LIKE 'performance_schema';
-- performance_schema | ON
```

If you see `OFF`, enable it in `my.cnf`:

```ini
[mysqld]
performance_schema = ON
```

…and restart `mysqld`.

### 1.4 Splunk OTel Collector includes the receiver

The Splunk distro bundles `mysqlreceiver` (since v0.50+). No custom build
needed.

---

## 2. Collector configuration

Block used on `vm-mysql` (full config in [fix-traces-and-mysql-metrics.sh](../fix-traces-and-mysql-metrics.sh)):

```yaml
receivers:
  mysql:
    endpoint: 127.0.0.1:3306
    username: otel
    password: "${OTEL_PWD}"
    collection_interval: 30s
    # Opt-in metrics — disabled by default in the receiver.
    # Enable every one you want to graph or alert on.
    metrics:
      mysql.connection.count:        { enabled: true }
      mysql.connection.errors:       { enabled: true }
      mysql.client.network.io:       { enabled: true }
      mysql.query.count:             { enabled: true }
      mysql.query.slow.count:        { enabled: true }
      mysql.commands:                { enabled: true }
      mysql.prepared_statements:     { enabled: true }
      mysql.replica.time_behind_source: { enabled: true }
      mysql.replica.sql_delay:       { enabled: true }
      mysql.statement_event.count:   { enabled: true }
      mysql.statement_event.wait.time: { enabled: true }
      mysql.table.io.wait.count:     { enabled: true }
      mysql.table.io.wait.time:      { enabled: true }
      mysql.table.lock_wait.read.count:  { enabled: true }
      mysql.table.lock_wait.read.time:   { enabled: true }
      mysql.table.lock_wait.write.count: { enabled: true }
      mysql.table.lock_wait.write.time:  { enabled: true }

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
      receivers:  [mysql, hostmetrics]
      processors: [resourcedetection, resource/normalize_host, batch]
      exporters:  [signalfx]
```

### Connection options worth knowing

| Option | Default | Notes |
|---|---|---|
| `endpoint` | `127.0.0.1:3306` | Use `unix:///var/run/mysqld/mysqld.sock` for socket auth |
| `transport` | `tcp` | Or `unix` |
| `database` | (none) | Restrict info_schema scrapes to one DB |
| `collection_interval` | `10s` | We use 30s to reduce noise |
| `tls` | disabled | Block with `insecure: false` + CA file when using TLS |

---

## 3. Metrics produced

Default-enabled (always on):

`mysql.buffer_pool.data_pages`, `mysql.buffer_pool.limit`,
`mysql.buffer_pool.operations`, `mysql.buffer_pool.page_flushes`,
`mysql.buffer_pool.pages`, `mysql.buffer_pool.usage`, `mysql.handlers`,
`mysql.double_writes`, `mysql.locks`, `mysql.log_operations`,
`mysql.operations`, `mysql.page_operations`, `mysql.row_locks`,
`mysql.row_operations`, `mysql.sorts`, `mysql.threads`, `mysql.tmp_resources`,
`mysql.uptime`, `mysql.locked_connects`, `mysql.opened_resources`.

Opt-in (enable explicitly):

| Metric | Prereq |
|---|---|
| `mysql.connection.count` | `SHOW GLOBAL STATUS` (always available) |
| `mysql.connection.errors` | as above |
| `mysql.client.network.io` | as above |
| `mysql.query.count`, `mysql.query.slow.count` | as above |
| `mysql.commands` | `performance_schema` |
| `mysql.prepared_statements` | `performance_schema` |
| `mysql.statement_event.*` | `performance_schema.events_statements_summary_by_digest` |
| `mysql.table.io.wait.*` | `performance_schema.table_io_waits_summary_by_table` |
| `mysql.table.lock_wait.*` | `performance_schema.table_lock_waits_summary_by_table` |
| `mysql.replica.*` | `SHOW REPLICA STATUS` (requires `REPLICATION CLIENT`) |

Full schema:
<https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/receiver/mysqlreceiver/metadata.yaml>

---

## 4. Verification

```bash
# 1. User can connect & query
mysql -u otel -p"$OTEL_PWD" -e "SHOW GLOBAL STATUS LIKE 'Uptime'"

# 2. performance_schema accessible
mysql -u otel -p"$OTEL_PWD" -e "
  SELECT COUNT(*) FROM performance_schema.events_statements_summary_by_digest;"

# 3. Receiver pulling
curl -s http://127.0.0.1:8888/metrics | grep mysql
# otelcol_receiver_accepted_metric_points{receiver="mysql",transport=""} 3312

# 4. In Splunk Metric Finder, search:
#    mysql.connection.count, mysql.query.slow.count, mysql.buffer_pool.usage, …
```

In Splunk Observability → **Infrastructure → MySQL** built-in navigator will
populate automatically once `host.name` matches the host dimension.

---

## 5. Common pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| Collector logs `Error 1045: Access denied for user 'otel'@…` | Wrong host in user grant | `CREATE USER 'otel'@'<collector-host>'` |
| All default metrics flow, opt-in ones missing | `performance_schema = OFF` | Enable in `my.cnf` and restart |
| `mysql.replica.*` missing | No `REPLICATION CLIENT` grant or not a replica | Grant it or accept the absence |
| `Connection refused` from receiver | MySQL bound on `127.0.0.1` only | Edit `mysqld.cnf` `bind-address`; reorder conf files; reload |
| Numbers in Splunk look stale | `collection_interval` too high | Lower to 10–30s |
| Optional `mysql.statement_event.*` missing despite `performance_schema = ON` | `events_statements_summary_by_digest` consumer disabled | `UPDATE performance_schema.setup_consumers SET ENABLED='YES' WHERE NAME LIKE 'events_statements_%';` |
| Host card in Splunk Infrastructure not linked to mysql metrics | `host.name` mismatch | `resource/normalize_host` processor (see PHP doc §1.5) |

---

## 6. References

- Source: <https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/receiver/mysqlreceiver>
- MySQL `performance_schema`: <https://dev.mysql.com/doc/refman/8.0/en/performance-schema.html>
- Splunk Observability MySQL nav: <https://docs.splunk.com/observability/en/data-visualization/dashboards/builtin-dashboards-mysql.html>
