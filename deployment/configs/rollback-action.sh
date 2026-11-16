#!/usr/bin/env bash
# Lab 5 rollback action for the northstar-churn-prod canary.
# Fired when northstar-churn-rollback-canary-latency-p95 (rollback-alarm.json)
# goes to ALARM: sends all traffic to "champion" and sets "canary" to weight 0.
# Takes ~90 s; the endpoint reports Updating but keeps serving. This does NOT
# stop the canary instance billing - only deleting the endpoint does.
# Only weights change here: instance counts belong to auto-scaling.
set -euo pipefail
EP=northstar-churn-prod
aws sagemaker update-endpoint-weights-and-capacities --endpoint-name "$EP" \
  --desired-weights-and-capacities \
    VariantName=champion,DesiredWeight=1 \
    VariantName=canary,DesiredWeight=0
echo "Rollback requested; waiting for InService..."
aws sagemaker wait endpoint-in-service --endpoint-name "$EP"
aws sagemaker describe-endpoint --endpoint-name "$EP" \
  --query 'ProductionVariants[].[VariantName,CurrentWeight]' --output text
