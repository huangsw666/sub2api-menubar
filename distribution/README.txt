Sub2API Menu Bar
================

Requirements: macOS 13 or newer.

Installation
------------

1. Open install.command.
2. If macOS blocks it, Control-click install.command, choose Open, then confirm.
3. Edit this file after the first install:

   ~/Library/Application Support/Sub2APIMenuBar/config.json

4. Restart the service after editing:

   launchctl kickstart -k "gui/$(id -u)/io.github.huangsw666.sub2api-menubar"

Third-party relays are discovered automatically from Sub2API account records.
The Sub2API account name must match the relay API key name (case-insensitive).

The app is ad-hoc signed but not notarized. It stores login tokens in macOS
Keychain and keeps credentials out of config.json. After you approve
install.command, it removes quarantine from only the installed app bundle so
launchd can start it.

When upgrading from the original local.ai-latency-monitor prototype, the
installer migrates its configuration and the app securely imports matching
Keychain tokens on first use. macOS may request confirmation once.

Uninstallation
--------------

Open uninstall.command. It removes the LaunchAgent but retains the app,
configuration, and Keychain tokens.
