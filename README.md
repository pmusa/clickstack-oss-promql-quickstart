# ClickStack locally, with Grafana and PromQL on top

A single-command local observability stack:

- **ClickStack all-in-one** — HyperDX UI + OpenTelemetry collector + ClickHouse + MongoDB in one container
- **Sample telemetry** — the official logs / traces / metrics dataset, loaded over OTLP
- **Grafana** — ClickHouse and Prometheus datasources plus a ready-made dashboard, provisioned on startup
- **Prometheus** — scrapes local targets and stores every sample **in ClickHouse** (`TimeSeries` engine), then reads it back for PromQL

| Service | URL | Credentials |
| --- | --- | --- |
| ClickStack (HyperDX) UI | http://localhost:8080 | create on first visit |
| Grafana | http://localhost:3000 | opens straight in (or `admin` / `admin`) |
| Prometheus | http://localhost:9090 | — |
| ClickHouse HTTP / native | http://localhost:8123 · `9000` | `default`, no password |
| ClickHouse Prometheus endpoints | `:9363` `/metrics` `/write` `/read` | — |
| OTLP ingest | `:4318` (HTTP) · `:4317` (gRPC) | see [Step 2](#step-2--load-the-sample-data) |

Verified on macOS (Apple silicon) with Docker 29.7, ClickStack 2.38.0, ClickHouse 26.5.7, Grafana 13.2.1.

---

## Prerequisites

Docker with Compose v2, and ~4 GB of free memory. That's it.

---

## Step 1 — Start everything

```bash
docker compose up -d
```

First run pulls ~3.5 GB of images. ClickHouse reports healthy in about 20 seconds; the
HyperDX UI takes another 30–60 seconds to finish booting.

```bash
docker compose ps
```

The `clickstack` healthcheck deliberately waits for more than "is ClickHouse listening" —
it waits until `prom.metrics` exists, so Prometheus never starts writing to a table that
isn't there yet.

> **Just ClickStack, nothing else?** The all-in-one needs no compose file at all:
>
> ```bash
> docker run --name clickstack -p 8080:8080 -p 4317:4317 -p 4318:4318 -p 8123:8123 clickhouse/clickstack-all-in-one:latest
> ```
>
> Run one or the other — both bind the same ports.

---

## Step 2 — Load the sample data

```bash
./scripts/load-sample-data.sh
```

```
loading logs
loading traces
loading metrics
```

It's the loop from the ClickStack docs wrapped in a script: download the archive, then
POST all **4,329 payloads** over OTLP/HTTP — 1,867 logs, 1,795 traces, 667 metrics.
Nothing is sampled or truncated; the whole archive goes in. One request per payload, so
it takes a couple of minutes. Then give the collector ~30 s to flush its batches.

### The one thing the docs' loop is missing

The collector's auth behaviour flips the moment a team exists:

| | OTLP without `authorization` header | with a valid key |
| --- | --- | --- |
| Fresh container, **no account yet** | `200` accepted | `200` |
| **After** you register in the UI | **`401` rejected** | `200` |

The docs' loop sends no `authorization` header and uses `curl -s -o /dev/null`, which
discards the status code — so after you have registered, all 4,329 payloads come back
`401` while the loop still prints `loading logs / loading traces / loading metrics` and
exits `0`. It looks exactly like success and loads nothing.

So the script adds one line, `-H "authorization:${INGESTION_API_KEY:+ ...}"`, reading the
key from `INGESTION_API_KEY` or `.env` (pinned in `docker-compose.yml`). With no key set
the header is omitted, which is what a fresh container wants.

### If a view comes up empty, it's the timestamps

Every payload carries an **absolute `timeUnixNano`**, which makes this dataset a little
awkward to demo:

- It holds **15.2 minutes of events** — the same window across logs, traces and metrics.
  (`metrics.startTimeUnixNano` reaches ~70 min further back, but that's when the
  cumulative counters started, not when the data was recorded.)
- The published archive is **regenerated roughly every 25 minutes** (observed: `17:27:02`
  then `17:51:27` UTC), and its window ends only ~10 minutes after generation.
- **Between regenerations every download is byte-identical** — same MD5, same timestamps.

So depending on where you land in that cycle, a freshly downloaded archive can already be
20+ minutes old, and re-running the loader won't change that. The fix is simply to
**widen the time picker to `Last 1 hour`** — that always covers the data, since it is at
most ~25 min old plus its own 15 min span.

To check what you actually got, print the newest event in the archive:

```bash
date -r $(( $(tar -xOf sample.tar.gz logs.json \
  | grep -o '"timeUnixNano":"[0-9]\{19\}"' | grep -o '[0-9]\{19\}' \
  | sort -n | tail -1) / 1000000000 ))
```

If that time is well in the past, staleness is your answer — not the loader.

## Step 3 — Tour ClickStack · http://localhost:8080

Create an account on first visit (local only — any email works). The bundled ClickHouse
connection and the logs/traces/metrics sources are pre-configured, so you land on data
immediately.

Set the time picker to **Last 1 hour** and walk through:

| Where | What to look at |
| --- | --- |
| [Search](http://localhost:8080/search) | The default view. Search across 5,335 log rows in ~160 ms. Type `error` in the search bar, or switch the query language to SQL and edit the `SELECT` directly. |
| Search → sidebar | `ServiceName`, `ResourceAttributes {18}`, `LogAttributes {65}` — facets built from the OTel columns. Click a service to filter. |
| Search → **Event Patterns** | Groups thousands of similar log lines into a handful of templates. The fastest way to see what a noisy service is actually saying. |
| Search → a log row | Opens the side panel. If the row has a `TraceId`, jump straight from the log line to the **trace waterfall** and back. |
| [Service Map](http://localhost:8080/service-map) | The demo topology, sized by throughput and coloured by error rate (this dataset runs ~44% errors on some edges by design). Toggle Latency / Error rate / Throughput. |
| [Chart Explorer](http://localhost:8080/chart) | Ad-hoc charts over any source without writing SQL. |
| [Dashboards](http://localhost:8080/dashboards/list) · [Alerts](http://localhost:8080/alerts) | Save charts into dashboards; alerts can be attached to any saved search. |
| [Team Settings](http://localhost:8080/team) | Where the **Ingestion API Key** lives, plus connections and sources. |

Everything here is just SQL against ClickHouse underneath — which is what makes Step 4
possible with no extra plumbing.

---

## Step 4 — Tour Grafana · http://localhost:3000

Nothing to click through on setup: the ClickHouse plugin, both datasources and the
dashboard are provisioned from `grafana/provisioning/` at startup.

Open **[ClickStack tour](http://localhost:3000/d/clickstack-tour)** (folder *ClickStack*):

**Row 1 — the OTel data ClickStack collected**

- *Log volume by service* / *Errors by service* — stacked, straight off `default.otel_logs`
- *Span latency p50 / p95 / p99* — `quantile()` over `otel_traces.Duration`
- *Slowest operations (p95)* — top operations by tail latency, with an error %
- *Logs* — raw log lines in Grafana's logs panel

**Row 2 — Prometheus metrics living in ClickHouse** (that's [Step 5](#step-5--bonus-prometheus--clickhouse-timeseries-with-promql))

Every panel is a plain SQL query you can open and edit — click a panel title → **Edit**.
The two datasources are also wired up for [Explore](http://localhost:3000/explore):
pick **ClickHouse** for SQL against the OTel tables, or **Prometheus** for PromQL.

Try this in Explore → ClickHouse, to see the trace and log tables joined by trace ID:

```sql
SELECT t.ServiceName, t.SpanName, round(t.Duration / 1e6, 1) AS ms, l.Body
FROM default.otel_traces AS t
INNER JOIN default.otel_logs AS l ON l.TraceId = t.TraceId
WHERE t.Duration > 100000000
LIMIT 20
```

---

## Step 5 — Bonus: Prometheus → ClickHouse TimeSeries, with PromQL

Prometheus scrapes three local targets every 15 s — **node-exporter** (host CPU, memory,
disk), **ClickHouse's own `/metrics`**, and itself — and `remote_write`s every sample into
a ClickHouse [`TimeSeries`](https://clickhouse.com/docs/engines/table-engines/special/time_series)
table. Prometheus' own local TSDB is capped at a 2-hour window
(`--storage.tsdb.retention.time=2h`), so ClickHouse is the store of record — anything
older than that is answered from ClickHouse over `remote_read`.

```
node-exporter ─┐
ClickHouse     ├─scrape→ Prometheus ─remote_write→ ClickHouse prom.metrics (TimeSeries)
Prometheus     ─┘            ↑                              │
                             └────── remote_read ───────────┘
                                     ▲                       ▲
                      Grafana "Prometheus" DS      Grafana "ClickHouse" DS
                          (PromQL via              (PromQL evaluated *inside*
                           Prometheus)              ClickHouse)
```

Enabled by two small files: `clickhouse/config.d/prometheus.xml` (adds `/metrics`,
`/write` and `/read` handlers on port 9363) and `clickhouse/initdb/01-timeseries.sql`
(creates `prom.metrics`).

Check targets at http://localhost:9090/targets — all three should be **UP**.

### Two ways to run PromQL over it

**1. Real PromQL through Prometheus** (Grafana → Explore → *Prometheus*):

```promql
100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)
```

Prometheus is the query engine, but the samples come back out of ClickHouse over
`remote_read` (`read_recent: true`, so even recent windows are served from ClickHouse).
You can watch it happen:

```bash
docker exec clickstack clickhouse-client -q "SYSTEM FLUSH LOGS"
docker exec clickstack clickhouse-client -q "
SELECT count() AS remote_read_queries FROM system.query_log
WHERE event_time > now() - INTERVAL 5 MINUTE
  AND query LIKE '%timeSeries%' AND type = 'QueryFinish'"
```

**2. PromQL evaluated inside ClickHouse** — no Prometheus in the query path at all:

```bash
docker exec clickstack clickhouse-client \
  --dialect promql --promql_database prom --promql_table metrics \
  -q 'sum by (job) (up)'
```

or as a table function, which is what the Grafana panels use:

```sql
SELECT t.1 AS time, t.2 AS cpu_busy_pct
FROM prometheusQueryRange(
    prom.metrics,
    '100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[2m])) * 100)',
    now() - INTERVAL 30 MINUTE, now(), 30
)
ARRAY JOIN time_series AS t
ORDER BY time
```

And it is still ordinary SQL underneath — `timeSeriesData()`, `timeSeriesTags()` and
`timeSeriesMetrics()` expose the `TimeSeries` engine's inner tables:

```sql
SELECT metric_name, count() AS series
FROM timeSeriesTags(prom.metrics)
GROUP BY metric_name ORDER BY series DESC LIMIT 10
```

> The `rate(...[2m])` panels need a couple of minutes of scrapes before they draw
> anything. On a fresh stack, give it 5 minutes.
>
> Both the `TimeSeries` engine and the PromQL dialect are **experimental** in ClickHouse
> 26.5 — great for a demo, not yet for production.

---

## Verify the whole thing yourself

```bash
# Telemetry that ClickStack ingested
docker exec clickstack clickhouse-client -q "
SELECT 'otel_logs' AS table, count() AS rows FROM default.otel_logs
UNION ALL SELECT 'otel_traces', count() FROM default.otel_traces
UNION ALL SELECT 'otel_metrics_sum', count() FROM default.otel_metrics_sum
UNION ALL SELECT 'hyperdx_sessions', count() FROM default.hyperdx_sessions
ORDER BY 1 FORMAT PrettyCompact"

# Prometheus samples now living in ClickHouse
docker exec clickstack clickhouse-client -q "
SELECT count() AS samples FROM timeSeriesData(prom.metrics);
SELECT count() AS series FROM timeSeriesTags(prom.metrics)"
```

A freshly loaded stack shows roughly 5,300 logs, 25,800 spans, 89,000 metric points and
10,400 session records, plus a few thousand Prometheus samples that keep climbing.

Logs look short? They aren't lost — the collector routes RUM/session-shaped records into
`hyperdx_sessions`, so `otel_logs + hyperdx_sessions` accounts for all of them.

---

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| Loader prints `401` and exits | You created an account, so the collector now enforces auth. `INGESTION_API_KEY` in `.env` should cover it; otherwise copy the key from **Team Settings → Ingestion API Key** and re-run with `INGESTION_API_KEY=<key> ./scripts/load-sample-data.sh`. |
| UI shows no data | Widen the time picker to **Last 1 hour** and give the collector ~30 s to flush. Still empty? Print the archive's newest event (snippet in [Step 2](#step-2--load-the-sample-data)) — if it is well in the past, that's the cause. |
| `Authentication failed: password is incorrect` from ClickHouse | The stock entrypoint pins `default` to localhost when no password is set. `clickhouse/users.d/zz-demo-access.xml` re-opens it — make sure that mount is present. |
| Prometheus target `clickhouse` DOWN | `curl -s localhost:9363/metrics \| head` — if empty, `config.d/prometheus.xml` isn't mounted. |
| `node-exporter` won't start | Docker refusing the `/proc` `/sys` mounts. It's optional: `docker compose stop node-exporter` and the rest still works. |
| Grafana panel: `frame 0 is missing long type indicator` | ClickHouse plugin `format`: `0` = time series (wide), `1` = table, `2` = logs. |
| PromQL panels empty, `NOT_ENOUGH_SPACE` in the logs | **Docker's disk is full**, not a problem with this stack. `docker system df` — then reclaim build cache (`docker builder prune`) or unused images (`docker image prune -a`). This stack is small: ~750 MB of volumes, and `prom.metrics` holds 2.6M samples in **3.5 MiB** (ClickHouse compresses metrics to ~1.4 bytes/sample), so metric growth is not what fills a disk. Prometheus resumes writing once space is free, leaving a gap for the outage. |

Logs live inside the all-in-one container:

```bash
docker exec clickstack sh -c 'tail -40 /var/log/app.log /var/log/otel-collector.log /var/log/clickhouse.log'
```

OpAMP `connection refused` errors during the first ~30 s are harmless startup retries.

---

## Reset and teardown

```bash
docker compose stop            # keep everything
docker compose down            # remove containers, keep data
docker compose down -v         # full reset: telemetry, account, dashboards, metrics
```

---

## Locking it down

This is a laptop demo and it is wired for convenience, not safety. Before running it
anywhere that isn't your own machine:

- **ClickHouse `default` has no password** and `clickhouse/users.d/zz-demo-access.xml`
  re-opens it to every network, with `8123`/`9000`/`9363` published to the host. Set
  `CLICKHOUSE_PASSWORD`, drop that override, and stop publishing those ports.
- **Grafana allows anonymous Admin** (`GF_AUTH_ANONYMOUS_ENABLED`) and uses `admin`/`admin`.
- **The ingestion key is pinned in `.env`** and committed-by-default. Real deployments
  should let ClickStack generate it.
- **The ClickHouse Prometheus `/write` and `/read` handlers are unauthenticated.**

---

## Layout

```
docker-compose.yml                              the whole stack
.env                                            pinned INGESTION_API_KEY
clickhouse/config.d/prometheus.xml              /metrics + remote_write + remote_read on :9363
clickhouse/users.d/zz-demo-access.xml           re-opens `default` to the container network
clickhouse/initdb/01-timeseries.sql             CREATE TABLE prom.metrics ENGINE = TimeSeries
prometheus/prometheus.yml                       scrape targets + remote_write/remote_read
grafana/provisioning/datasources/               ClickHouse + Prometheus datasources
grafana/provisioning/dashboards/                dashboard file provider
grafana/dashboards/clickstack-tour.json         the 10-panel tour dashboard
scripts/load-sample-data.sh                     OTLP sample-data loader
```

## References

- [ClickStack docs](https://clickhouse.com/docs/use-cases/observability/clickstack)
- [ClickHouse `TimeSeries` engine](https://clickhouse.com/docs/engines/table-engines/special/time_series)
- [ClickHouse Prometheus protocols](https://clickhouse.com/docs/interfaces/prometheus)
- [Grafana ClickHouse datasource](https://github.com/grafana/clickhouse-datasource)
