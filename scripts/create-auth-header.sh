#!/usr/bin/env bash
# Generate the Base64-encoded Basic Auth header value for OTEL_EXPORTER_OTLP_HEADERS.
# Password is read via prompt so it never appears in command history.
set -euo pipefail

read -r -s -p 'Enter OTel password: ' password; echo

encoded=$(printf 'claude:%s' "$password" | base64)
password=''

echo ''
echo 'Add the following to ~/.claude/settings.json:'
echo ''
echo "  \"OTEL_EXPORTER_OTLP_HEADERS\": \"Authorization=Basic ${encoded}\""
