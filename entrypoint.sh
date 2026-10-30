#!/bin/sh
set -e
# Cloud Run mounts the rmapi token (Secret Manager) read-only at /secrets/rmapi.conf.
if [ -f /secrets/rmapi.conf ]; then
  cp /secrets/rmapi.conf "$RMAPI_CONFIG"
fi
if [ "$1" = "rmapi" ]; then
  exec "$@"
fi
exec python /app/newsletter2rm.py "$@"
