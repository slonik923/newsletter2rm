#!/usr/bin/env bash
# Deploy newsletter2rm as a Cloud Run Job triggered by Cloud Scheduler.
# Usage: PROJECT=my-project ./deploy.sh     (needs ./rmapi.conf from the pairing step)
set -euo pipefail

PROJECT="${PROJECT:?set PROJECT to the GCP project id}"
REGION="${REGION:-europe-west3}"
SCHEDULE="${SCHEDULE:-0 */3 * * *}"   # every 3 hours
NAME=newsletter2rm
BUCKET="gs://${PROJECT}-${NAME}"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT}/${NAME}/${NAME}"
SA="${NAME}@${PROJECT}.iam.gserviceaccount.com"
g() { gcloud --project "$PROJECT" "$@"; }

[ -f rmapi.conf ] || { echo "rmapi.conf missing - pair first (see README)"; exit 1; }

g services enable run.googleapis.com cloudscheduler.googleapis.com secretmanager.googleapis.com \
  artifactregistry.googleapis.com cloudbuild.googleapis.com

g iam service-accounts describe "$SA" >/dev/null 2>&1 \
  || g iam service-accounts create "$NAME" --display-name "newsletter to reMarkable"

g storage buckets describe "$BUCKET" >/dev/null 2>&1 \
  || g storage buckets create "$BUCKET" --location "$REGION" --uniform-bucket-level-access
g storage buckets add-iam-policy-binding "$BUCKET" --member "serviceAccount:$SA" \
  --role roles/storage.objectAdmin >/dev/null

if g secrets describe rmapi-conf >/dev/null 2>&1; then
  g secrets versions add rmapi-conf --data-file rmapi.conf
else
  g secrets create rmapi-conf --data-file rmapi.conf --replication-policy automatic
fi
g secrets add-iam-policy-binding rmapi-conf --member "serviceAccount:$SA" \
  --role roles/secretmanager.secretAccessor >/dev/null

g artifacts repositories describe "$NAME" --location "$REGION" >/dev/null 2>&1 \
  || g artifacts repositories create "$NAME" --location "$REGION" --repository-format docker
g builds submit --tag "$IMAGE" .

g run jobs deploy "$NAME" --region "$REGION" --image "$IMAGE" \
  --service-account "$SA" \
  --set-secrets "/secrets/rmapi.conf=rmapi-conf:latest" \
  --set-env-vars "STATE_URI=${BUCKET}/state.json" \
  --memory 2Gi --cpu 1 --task-timeout 15m --max-retries 1

g run jobs add-iam-policy-binding "$NAME" --region "$REGION" \
  --member "serviceAccount:$SA" --role roles/run.invoker >/dev/null

RUN_URI="https://run.googleapis.com/v2/projects/${PROJECT}/locations/${REGION}/jobs/${NAME}:run"
if g scheduler jobs describe "$NAME" --location "$REGION" >/dev/null 2>&1; then
  g scheduler jobs update http "$NAME" --location "$REGION" --schedule "$SCHEDULE" \
    --uri "$RUN_URI" --http-method POST --oauth-service-account-email "$SA"
else
  g scheduler jobs create http "$NAME" --location "$REGION" --schedule "$SCHEDULE" \
    --uri "$RUN_URI" --http-method POST --oauth-service-account-email "$SA"
fi

echo "Deployed. Run now with: gcloud --project $PROJECT run jobs execute $NAME --region $REGION"
