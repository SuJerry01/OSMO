#!/usr/bin/env bash
# Tear down the NEW KIND-based OSMO deployment (clean, one command).
set -uo pipefail
echo "==> Deleting KIND cluster 'osmo' (removes all pods, PVs, Postgres data)"
kind delete cluster --name osmo
echo "==> Removing localstack S3 host dir"
rm -rf /tmp/localstack-s3 2>/dev/null || true
echo "==> Done. (Keeps kind/nvkind binaries, helm repos, and the osmo CLI.)"
