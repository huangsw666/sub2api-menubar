#!/bin/zsh
set -euo pipefail
PACKAGE_DIR=${0:A:h}
/usr/bin/python3 "$PACKAGE_DIR/installer.py" uninstall --project-dir "$PACKAGE_DIR"
echo
echo "Uninstall complete. Press Return to close this window."
read -r
