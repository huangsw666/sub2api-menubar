#!/bin/zsh
set -euo pipefail
PACKAGE_DIR=${0:A:h}
/usr/bin/python3 "$PACKAGE_DIR/installer.py" install \
  --project-dir "$PACKAGE_DIR" \
  --prebuilt-app "$PACKAGE_DIR/Sub2API Menu Bar.app" \
  --migrate-legacy
echo
echo "Installation complete. Press Return to close this window."
read -r
