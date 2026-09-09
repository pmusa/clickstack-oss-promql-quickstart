#!/usr/bin/env bash
#
# Download the ClickStack sample dataset and POST it over OTLP/HTTP.
# This is the loop from the ClickStack docs, wrapped: download, then load.
#
# The one addition is the `authorization` header. As soon as you create an
# account in the UI the collector starts enforcing the ingestion key, and
# without the header every POST comes back 401 while the loop still prints
# "loading ..." and exits 0 - looking exactly like success. The key comes from
# INGESTION_API_KEY, falling back to .env; with no key at all the header is
# omitted, which is what a fresh container (no account yet) wants.
#
# Takes a few minutes - one request per payload, 4,329 of them.
#
set -euo pipefail

cd "$(dirname "$0")/.."

API_KEY="${INGESTION_API_KEY:-$(sed -n 's/^INGESTION_API_KEY=//p' .env 2>/dev/null | head -1)}"

curl -O -s https://storage.googleapis.com/hyperdx/sample.tar.gz

for filename in $(tar -tf sample.tar.gz); do
  endpoint="http://localhost:4318/v1/${filename%.json}"
  echo "loading ${filename%.json}"
  tar -xOf sample.tar.gz "$filename" | while read -r line; do
    printf '%s\n' "$line" | curl -s -o /dev/null -X POST "$endpoint" \
    -H "Content-Type: application/json" \
    -H "authorization:${API_KEY:+ $API_KEY}" \
    --data-binary @-
  done
done
