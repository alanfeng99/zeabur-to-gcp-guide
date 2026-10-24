#!/usr/bin/env bash
# One-time, idempotent setup that Terraform cannot do for itself: create the
# project, link billing, and create the bucket that holds Terraform's state.
# Everything else in the project is managed from envs/<env>/.
#
#   ./bootstrap.sh <project-id> <billing-account-id> [region]
set -euo pipefail

PROJECT_ID=${1:?usage: bootstrap.sh <project-id> <billing-account-id> [region]}
BILLING_ACCOUNT=${2:?usage: bootstrap.sh <project-id> <billing-account-id> [region]}
REGION=${3:-asia-east1}
STATE_BUCKET="gs://${PROJECT_ID}-tfstate"

if gcloud projects describe "$PROJECT_ID" >/dev/null 2>&1; then
  echo "project $PROJECT_ID already exists"
else
  gcloud projects create "$PROJECT_ID" --name="$PROJECT_ID"
fi

gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT"

gcloud services enable \
  cloudbilling.googleapis.com \
  cloudresourcemanager.googleapis.com \
  serviceusage.googleapis.com \
  storage.googleapis.com \
  --project "$PROJECT_ID"

if gcloud storage buckets describe "$STATE_BUCKET" >/dev/null 2>&1; then
  echo "state bucket $STATE_BUCKET already exists"
else
  gcloud storage buckets create "$STATE_BUCKET" \
    --project "$PROJECT_ID" \
    --location "$REGION" \
    --uniform-bucket-level-access \
    --public-access-prevention
fi
# Versioned, so a corrupted or mistakenly overwritten state can be rolled back.
gcloud storage buckets update "$STATE_BUCKET" --versioning
