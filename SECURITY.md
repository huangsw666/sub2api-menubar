# Security Policy

## Supported versions

Security fixes are currently made against the latest release only.

## Reporting a vulnerability

Please report vulnerabilities through GitHub's private security advisory
feature instead of a public issue. Do not include active tokens, API keys,
private URLs, or unredacted responses in any report.

The app stores login tokens in macOS Keychain under
`io.github.huangsw666.sub2api-menubar`. The JSON configuration must not contain
credentials. The current release performs read-only API requests.

Self-hosted Sub2API and relay deployments remain the operator's responsibility.
Prefer HTTPS and do not expose administrator endpoints directly to untrusted
networks.
