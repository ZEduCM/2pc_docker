#!/usr/bin/env bash
set -euo pipefail

PRUNE=0
if [[ "${1:-}" == "--prune-data" ]]; then
  PRUNE=1
fi

if [[ $PRUNE -eq 1 ]]; then
  docker compose down -v
else
  docker compose down
fi