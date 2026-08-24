# Contributing

Bug reports, API compatibility samples, and focused pull requests are welcome.

Before opening an issue, remove access tokens, API keys, private hostnames,
IP addresses, account IDs, email addresses, and full API responses. A minimal
redacted JSON shape is usually enough to diagnose parser compatibility.

For code changes:

1. Fork the repository and create a focused branch.
2. Build with the command in `README.md` on macOS 13 or newer.
3. Keep monitoring read-only unless the change is explicitly part of an
   approved account-control feature.
4. Describe the Sub2API or upstream API version used for verification.
5. Open a pull request explaining behavior, validation, and security impact.

By contributing, you agree that your contribution is licensed under the MIT
License.

## Releases

Update `VERSION` and `CFBundleVersion` in `scripts/installer.py`, add the
release notes to `CHANGELOG.md`, and push those changes to `main`. Publishing
a matching version tag triggers the release workflow automatically:

```bash
git tag v0.2.3
git push origin v0.2.3
```

The workflow verifies that the tag matches `VERSION`, builds the universal
macOS package, checks its SHA-256 digest, and creates the GitHub Release with
both files attached.
