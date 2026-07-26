# OpenFaaS function image: Bun (runs TS natively) behind of-watchdog. Built by faas-cli.
# Mirrors the co-latro-admin function images so there is one shape to reason about.
FROM ghcr.io/openfaas/of-watchdog:0.10.7 AS watchdog
FROM oven/bun:1

COPY --from=watchdog /fwatchdog /usr/bin/fwatchdog
RUN chmod +x /usr/bin/fwatchdog

WORKDIR /app
COPY package.json ./
RUN bun install
COPY . .

# of-watchdog (http mode) runs the Bun server on :3000 and proxies :8080 -> :3000.
# Timeouts sit above the function's own PVE_TIMEOUT_MS (6s) x 2 nodes + slack.
ENV mode=http \
    upstream_url=http://127.0.0.1:3000 \
    fprocess="bun run server.ts" \
    exec_timeout=30s \
    write_timeout=35s \
    read_timeout=35s
EXPOSE 8080
CMD ["fwatchdog"]
