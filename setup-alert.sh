#!/usr/bin/env bash
# One-time: email me when a newsletter2rm job execution fails.
# Usage: PROJECT=my-project ALERT_EMAIL=me@example.com ./setup-alert.sh
set -euo pipefail

PROJECT="${PROJECT:?set PROJECT to the GCP project id}"
ALERT_EMAIL="${ALERT_EMAIL:?set ALERT_EMAIL}"
NAME=newsletter2rm
g() { gcloud --project "$PROJECT" "$@"; }

g services enable monitoring.googleapis.com

CHANNEL=$(g beta monitoring channels list --filter "type=\"email\" AND labels.email_address=\"${ALERT_EMAIL}\"" --format 'value(name)' | head -1)
if [ -z "$CHANNEL" ]; then
  CHANNEL=$(g beta monitoring channels create --type email --display-name "$ALERT_EMAIL" \
    --channel-labels "email_address=${ALERT_EMAIL}" --format 'value(name)')
fi

POLICY=$(mktemp)
trap 'rm -f "$POLICY"' EXIT
cat > "$POLICY" <<EOF
{
  "displayName": "${NAME} job failed",
  "documentation": {
    "content": "A ${NAME} run failed, so new posts are not reaching the reMarkable. Check the job logs. If rmapi auth fails, re-pair (README) and run deploy.sh to update the secret.",
    "mimeType": "text/markdown"
  },
  "combiner": "OR",
  "conditions": [{
    "displayName": "failed execution",
    "conditionThreshold": {
      "filter": "resource.type=\"cloud_run_job\" AND resource.label.job_name=\"${NAME}\" AND metric.type=\"run.googleapis.com/job/completed_execution_count\" AND metric.label.result=\"failed\"",
      "aggregations": [{"alignmentPeriod": "300s", "perSeriesAligner": "ALIGN_SUM", "crossSeriesReducer": "REDUCE_SUM"}],
      "comparison": "COMPARISON_GT",
      "thresholdValue": 0,
      "duration": "0s"
    }
  }],
  "alertStrategy": {"autoClose": "86400s"},
  "notificationChannels": ["${CHANNEL}"]
}
EOF

EXISTING=$(g alpha monitoring policies list --filter "displayName=\"${NAME} job failed\"" --format 'value(name)' | head -1)
if [ -n "$EXISTING" ]; then
  g alpha monitoring policies update "$EXISTING" --policy-from-file "$POLICY"
else
  g alpha monitoring policies create --policy-from-file "$POLICY"
fi
