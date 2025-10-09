#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <certificate-path>" >&2
  exit 1
fi

CERT_PATH="$1"
if [[ ! -f "$CERT_PATH" ]]; then
  echo "Certificate not found: $CERT_PATH" >&2
  exit 1
fi

openssl x509 -in "$CERT_PATH" -noout -fingerprint -sha256 \
  | cut -d'=' -f2 \
  | tr -d ':' \
  | tr 'A-F' 'a-f'
