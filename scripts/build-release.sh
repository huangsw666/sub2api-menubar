#!/bin/zsh
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
/usr/bin/python3 "$PROJECT_DIR/scripts/installer.py" package \
  --project-dir "$PROJECT_DIR" \
  --output-dir "$PROJECT_DIR/dist"
