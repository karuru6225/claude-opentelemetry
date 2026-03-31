#!/usr/bin/env bash
# Generate otel.htpasswd and print the OTEL_EXPORTER_OTLP_HEADERS value.
# Password is read via prompt so it never appears in command history.
set -euo pipefail

read -r -s -p 'Enter OTel password: ' password; echo
read -r -s -p 'Confirm password: '    confirm;  echo

if [[ "$password" != "$confirm" ]]; then
  echo 'Passwords do not match.' >&2
  exit 1
fi

# Generate bcrypt hash via docker and write to otel.htpasswd
printf '%s' "$password" | docker run --rm -i httpd htpasswd -niB claude > otel.htpasswd

encoded=$(printf 'claude:%s' "$password" | base64)
password=''
confirm=''

echo ''
echo '==> otel.htpasswd created.'
echo ''
echo 'Add the following to ~/.claude/settings.json:'
echo ''
echo "  \"OTEL_EXPORTER_OTLP_HEADERS\": \"Authorization=Basic ${encoded}\""
