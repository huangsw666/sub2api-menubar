# Changelog

All notable changes to this project will be documented in this file.

## [0.2.3] - 2026-08-24

### Added

- GitHub Actions CI for compiling and verifying universal macOS packages
- Automatic GitHub Release publishing for version tags

## [0.2.2] - 2026-08-24

### Fixed

- Refresh expired relay sessions before retrying authenticated requests
- Keep relay balance and multiplier available when channel-monitor data is missing
- Clear stale relay metrics when authentication has expired
- Reuse account rows and recent-latency labels to prevent AppKit objects from accumulating during periodic refreshes
- Release temporary login and session-restoration WebViews after they finish

## [0.2.1] - 2026-08-18

### Fixed

- Read ArithCore group multipliers from `/api/user/self/groups` before falling back to legacy ratio endpoints
- Send ArithCore's `New-Api-User` header only to ArithCore upstreams
- Avoid displaying unavailable channel metrics for upstreams without channel-monitor support

## [0.2.0] - 2026-08-17

### Added

- Single scrollable overview with OAuth quota and API key relay summaries
- Per-account scheduling switch backed by the Sub2API schedulable API
- Confirmation before pausing the account used by the latest request
- Protection against disabling the last schedulable account
- Selective third-party relay login with persistent per-account skip state
- Bounded concurrent relay monitoring and independent per-account error states

### Changed

- Third-party relay login is no longer opened automatically
- Schedulable accounts are sorted before paused accounts; paused accounts are ordered by recent use
- Recent TTFT values use a larger one-decimal display and secondary text is easier to read
- Popover height is increased by 50% to show more upstream accounts at once

## [0.1.2] - 2026-08-17

### Fixed

- Automatically discover third-party relay origins from Sub2API account credentials
- Match relay API keys to Sub2API account names without manual adapters
- Query channel health only after discovering the matched key's actual group
- Keep manual upstream entries as optional overrides for non-standard relays

## [0.1.1] - 2026-08-17

### Added

- Universal Apple Silicon and Intel release package
- Precompiled app installation without Xcode
- Automatic configuration and Keychain token migration from the original local prototype
- SHA-256 checksum for release downloads

## [0.1.0] - 2026-08-17

### Added

- Native macOS menu bar display for latest TTFT and total duration
- Detection of the upstream account used by the latest Sub2API request
- OAuth subscription quota display for 5-hour and 7-day windows
- Configurable API key relay adapters for balance and channel health
- Group multiplier, concurrency, PING, and 7-day availability display
- Web login with token storage in macOS Keychain
- LaunchAgent installer, status command, and non-destructive uninstaller
