#!/usr/bin/env bash

set -euo pipefail

ACCOUNT_ID=$(aws sts get-caller-identity \
  --query Account \
  --output text)

REGION=${AWS_REGION:-us-east-1}
REPOSITORY=devops-tools

IMAGE="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${REPOSITORY}:latest"

aws ecr get-login-password --region "${REGION}" | \
docker login \
  --username AWS \
  --password-stdin \
  "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

docker pull "${IMAGE}"

docker run --rm \
  -v /etc/hosts:/etc/hosts:ro \
  "${IMAGE}"
