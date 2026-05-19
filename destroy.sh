#!/usr/bin/env bash
# Tear down everything created by deploy.sh
set -euo pipefail
RESOURCE_GROUP="${RESOURCE_GROUP:-o11y-lamp-rg}"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-e77116d5-21bd-4488-ba12-20faa5c11605}"
az account set --subscription "$SUBSCRIPTION_ID"
echo "Deleting resource group $RESOURCE_GROUP ..."
az group delete -n "$RESOURCE_GROUP" --yes --no-wait
echo "Delete requested (running in background)."
