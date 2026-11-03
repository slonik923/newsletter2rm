#!/usr/bin/env bash
# One-time: let GitHub Actions deploy via Workload Identity Federation (no stored keys).
# Usage: PROJECT=my-project REPO=owner/newsletter2rm ./setup-github-deploy.sh   (after deploy.sh)
set -euo pipefail

PROJECT="${PROJECT:?set PROJECT to the GCP project id}"
REPO="${REPO:?set REPO to owner/name of the GitHub repo}"
REGION="${REGION:-europe-west3}"
NAME=newsletter2rm
DEPLOYER="github-deployer@${PROJECT}.iam.gserviceaccount.com"
g() { gcloud --project "$PROJECT" "$@"; }
NUM=$(g projects describe "$PROJECT" --format='value(projectNumber)')

g services enable iamcredentials.googleapis.com sts.googleapis.com

g iam workload-identity-pools describe github --location global >/dev/null 2>&1 \
  || g iam workload-identity-pools create github --location global --display-name "GitHub Actions"
g iam workload-identity-pools providers describe github --workload-identity-pool github --location global >/dev/null 2>&1 \
  || g iam workload-identity-pools providers create-oidc github --workload-identity-pool github --location global \
       --display-name "GitHub" --issuer-uri https://token.actions.githubusercontent.com \
       --attribute-mapping "google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref" \
       --attribute-condition "assertion.repository == '${REPO}'"

g iam service-accounts describe "$DEPLOYER" >/dev/null 2>&1 \
  || g iam service-accounts create github-deployer --display-name "GitHub Actions deployer"

# Only this repo may impersonate the deployer; the deployer may only push images and update the job.
g iam service-accounts add-iam-policy-binding "$DEPLOYER" --role roles/iam.workloadIdentityUser \
  --member "principalSet://iam.googleapis.com/projects/${NUM}/locations/global/workloadIdentityPools/github/attribute.repository/${REPO}" >/dev/null
g artifacts repositories add-iam-policy-binding "$NAME" --location "$REGION" \
  --member "serviceAccount:$DEPLOYER" --role roles/artifactregistry.writer >/dev/null
g run jobs add-iam-policy-binding "$NAME" --region "$REGION" \
  --member "serviceAccount:$DEPLOYER" --role roles/run.developer >/dev/null
g iam service-accounts add-iam-policy-binding "${NAME}@${PROJECT}.iam.gserviceaccount.com" \
  --member "serviceAccount:$DEPLOYER" --role roles/iam.serviceAccountUser >/dev/null

echo "Set in .github/workflows/deploy.yml:"
echo "  WIF_PROVIDER: projects/${NUM}/locations/global/workloadIdentityPools/github/providers/github"
echo "  DEPLOYER: ${DEPLOYER}"
