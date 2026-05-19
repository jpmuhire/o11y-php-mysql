# o11y PHP + MySQL on Azure

Two Azure Ubuntu 24.04 VMs wired to Splunk Observability:

| VM         | Public | Role                                                                                   |
|------------|--------|----------------------------------------------------------------------------------------|
| `vm-web`   | yes    | Apache + PHP 8 form (`index.php`) + Splunk OTel collector + `apache` receiver + PHP auto-instrumentation |
| `vm-mysql` | yes (SSH only) | MySQL 8 backing store + Splunk OTel collector + `mysql` receiver                |

Network: both VMs sit in `10.42.1.0/24` inside VNet `lamp-vnet`.
- NSG `nsg-web`: 22 + 80 open to the Internet.
- NSG `nsg-db`:  22 open to the Internet, **3306 only from `10.42.0.0/16`**.

## Prerequisites

- Azure CLI (`az`) signed in (`az login`)
- An SSH public key at `~/.ssh/id_rsa.pub` (override with `SSH_KEY_PATH`)
- Subscription ID baked into [deploy.sh](deploy.sh#L18) (override with `SUBSCRIPTION_ID`)
- Splunk realm + access token baked in (override with `SPLUNK_REALM`, `SPLUNK_ACCESS_TOKEN`)

## Deploy

```bash
cd o11y_php_mysql
chmod +x deploy.sh destroy.sh
./deploy.sh
```

The script:
1. Creates `o11y-lamp-rg` resource group in `westeurope`.
2. Creates VNet, subnet, two NSGs with the rules above.
3. Renders cloud-init from [cloud-init-mysql.yaml.tmpl](cloud-init-mysql.yaml.tmpl) and [cloud-init-web.yaml.tmpl](cloud-init-web.yaml.tmpl), embedding [app/index.php](app/index.php) into the web VM.
4. Creates both VMs with random MySQL passwords stored locally in `.secrets.env` (chmod 600, not committed).
5. Prints the public URL and SSH commands.

Cloud-init takes ~5–8 minutes per VM. Follow progress with:
```bash
ssh azureuser@<WEB_IP> sudo tail -f /var/log/cloud-init-output.log
```

## What gets installed

### vm-mysql
- `mysql-server` listening on `0.0.0.0:3306`
- Database `appdb`, table `entries`
- User `appuser` (remote, app), user `otel` (localhost, monitoring)
- Splunk OTel collector with config at [cloud-init-mysql.yaml.tmpl](cloud-init-mysql.yaml.tmpl) — pipelines:
  - `metrics`: `hostmetrics` + `mysql` → SignalFx
  - `traces`: `otlp` → Splunk APM

### vm-web
- Apache 2.4 + PHP 8 + `php-mysql`
- `mod_status` with `ExtendedStatus On` exposing `/server-status` to `127.0.0.1` (scraped by the `apache` receiver)
- App at `/var/www/html/index.php` — simple form (name/email/message) writing to MySQL via PDO
- DB credentials injected via Apache `SetEnv` (`DB_HOST`, `DB_USER`, `DB_PASS`, `DB_NAME`)
- Splunk OTel collector with `apache` receiver
- **Splunk Distribution of OpenTelemetry PHP** auto-instrumentation
  - `OTEL_SERVICE_NAME=php-lamp-demo`
  - traces exported via OTLP/HTTP to the local collector at `127.0.0.1:4318`
  - collector forwards traces to `ingest.<realm>.signalfx.com`

## Verify in Splunk Observability

1. **APM** → Services → `php-lamp-demo` (submit the form a few times to generate traces).
2. **Infrastructure** → Hosts → filter `deployment.environment=demo-o11y-lamp` → see `vm-web` and `vm-mysql`.
3. **Metric Finder**:
   - `apache.requests`, `apache.workers`, `apache.uptime`
   - `mysql.threads`, `mysql.operations`, `mysql.buffer_pool.usage`

## Smoke tests

```bash
# Web reachable
curl -s http://<WEB_IP>/ | head -20

# Submit a form entry
curl -s -X POST -d 'name=alice&email=a@example.com&message=hi' http://<WEB_IP>/

# Collector health (on each VM)
ssh azureuser@<IP> curl -s http://127.0.0.1:13133/

# MySQL from web VM
ssh azureuser@<WEB_IP> "mysql -h 10.42.1.10 -uappuser -p\$(grep APP_PWD .secrets.env|cut -d= -f2) appdb -e 'select count(*) from entries;'"
```

## Tear down

```bash
./destroy.sh
```

## Security notes

- The MySQL VM exposes SSH publicly for easy debugging; tighten `nsg-db.allow-ssh` to your IP for real use.
- `appuser` is granted on `appdb` only and bound to `'%'` (any host) but MySQL port is firewalled to the VNet.
- The Splunk access token is written to cloud-init `--custom-data`. Azure stores it encrypted at rest but anyone with `Microsoft.Compute/virtualMachines/*/read` on the RG can read it. Rotate after deployment if needed.
- Local `.secrets.env` is `chmod 600` and ignored by `.gitignore`.
