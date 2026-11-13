# Monitoring & Observability: Prometheus, Grafana, Loki, Alloy, Alertmanager

Metrics, logs, dashboards and alerting for a Python web app ("titan", Flask + `prometheus_client`),
the whole stack **provisioned as code** and started with one command.

> Built while following the *Decoding DevOps* course (Imran Teli, Udemy). The course installs each tool by hand
> on separate EC2 servers and clicks the dashboards together in the UI; this version is fully declarative.
> See **What I changed**.

## Architecture

```
 loadgen ──HTTP──▶ titan (Flask) ── /metrics ──┐
                     │ logs (/var/log/titan)    │ scrape every 15 s
 loggen ─────────────┤ INFO/WARNING/ERROR       ▼
                     ▼                     Prometheus ── alert rules ──▶ Alertmanager ──▶ webhook receiver
                   Alloy ──push──▶ Loki         ▲                                            (stand-in for Slack/Teams)
                                     │          │ node-exporter (CPU, memory, disk, network)
                                     └──▶ Grafana ◀──┘   provisioned data sources + dashboard
```

| Service | Port | Role |
|---|---|---|
| titan | 5000 | The app: `http_requests_total` counter + `http_request_duration_seconds` histogram |
| prometheus | 9090 | Scrapes metrics, evaluates `alerts.yml` |
| alertmanager | 9093 | Groups and routes alerts (firing + resolved) |
| grafana | 3000 | Dashboard "Titan app: metrics and logs" (7 panels), data sources Prometheus + Loki |
| loki | 3100 | Log storage, queried with LogQL |
| alloy | n/a | Tails the app's log files, extracts `level` (INFO/WARNING/ERROR), pushes to Loki |
| node-exporter | n/a | Host metrics |

## Run it

```bash
cd monitoring-lab
echo "GRAFANA_ADMIN_PASSWORD=<your-password>" > .env     # git-ignored
docker compose up -d --build
# Grafana http://localhost:3000 (admin) → Dashboards → VProfile → "Titan app: metrics and logs"
# Prometheus http://localhost:9090/alerts · Alertmanager http://localhost:9093
docker compose down -v
```

## Alerts (`monitoring-lab/prometheus/alerts.yml`)

| Alert | PromQL | For |
|---|---|---|
| TargetDown | `up == 0` | 30 s |
| HighRequestLatencyP95 | `histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket[2m]))) > 0.45` | 1 m |
| HighCPU | `100 - avg(rate(node_cpu_seconds_total{mode="idle"}[2m])) * 100 > 80` | 2 m |

**Verified end to end:** stopping the app fired `TargetDown` about a minute later; restarting it sent a
`resolved` notification. `HighRequestLatencyP95` fired on its own because the home page's p95 really is about
0.48 s (the app sleeps 0.1–0.5 s per request), and resolved when it dropped.

## Dashboard panels (PromQL / LogQL)

| Panel | Query |
|---|---|
| Requests/s by endpoint | `sum by (endpoint)(rate(http_requests_total[1m]))` |
| p95 latency by endpoint | `histogram_quantile(0.95, sum by (le,endpoint)(rate(http_request_duration_seconds_bucket[2m])))` |
| CPU % | `100 - avg(rate(node_cpu_seconds_total{mode="idle"}[1m])) * 100` |
| Memory % | `(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100` |
| Targets up | `up` |
| Log lines/min by level | `sum by (level)(count_over_time({job="titan"}[1m]))` |
| Error logs | `{job="titan", level="ERROR"}` |

## What I changed compared with the course

- **Everything provisioned from files**: Grafana data sources and the dashboard (JSON), Prometheus scrape config
  and alert rules, Alertmanager routing, Loki and Alloy configs. No UI clicking; reproducible in one command.
- **Security fix**: the course app ran Flask with `debug=True`, which exposes the Werkzeug debugger (remote code
  execution). Now it's off unless `FLASK_DEBUG=1`.
- **Alertmanager in the loop** with firing/resolved notifications to a webhook receiver (Slack/Teams just
  replace the receiver block).
- **Log levels as a Loki label**: one format-independent regex works for both the Python logs and the course's
  Apache-style generated logs.
- Containerised the app (`titan/Dockerfile`) and fixed the `requirments.txt` typo (`requirements.txt` added).

## Debugging notes

| Symptom | Cause | Fix |
|---|---|---|
| Alloy exits: `unknown escape sequence` | `\S` inside a normal `"..."` Alloy string | Use a backtick raw string |
| Only INFO logs in Loki | curl/Werkzeug normalise `..` paths, so the "bad request" never reached the app's error branch | Dedicated log generator; level regex matches both formats |
| node-exporter mount fails on Docker Desktop | `rslave` propagation isn't supported there | Plain read-only bind mount |

## Tech

Prometheus · PromQL · Alertmanager · Grafana (provisioning) · Loki · LogQL · Grafana Alloy · node-exporter ·
Python Flask + prometheus_client · Docker Compose
