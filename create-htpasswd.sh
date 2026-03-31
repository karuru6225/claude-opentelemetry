#!/usr/bin/env bash
# Generate otel.htpasswd interactively.
# Password is read via prompt so it never appears in command history.
set -euo pipefail

read -r -s -p 'Enter OTel password: ' password; echo
read -r -s -p 'Confirm password: '    confirm;  echo

if [[ "$password" != "$confirm" ]]; then
  echo 'Passwords do not match.' >&2
  exit 1
fi

# Generate bcrypt hash via docker and write to otel.htpasswd
# htpasswd -niB: read password from stdin, hash with bcrypt, print to stdout
printf '%s' "$password" | docker run --rm -i httpd htpasswd -niB claude > otel.htpasswd

password=''
confirm=''

echo '==> otel.htpasswd created.'
