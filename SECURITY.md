# Security Policy

## Supported versions

Cybokron Dock Groups is in early development. Security fixes are made on the `main` branch and
included in the next release; only the latest release is supported.

## Reporting a vulnerability

Please **do not** open a public issue for security problems.

Report privately through GitHub:
[Security → Report a vulnerability](https://github.com/ercanatay/cybokron-dock-groups/security/advisories/new).

Include what you found, steps to reproduce, the affected version and macOS version, and the
impact you expect. You can expect an initial reply within a few days. Once a fix is available,
the advisory will be published and you'll be credited unless you prefer otherwise.

## Scope

The app runs locally, has no network features and stores its data in
`~/Library/Application Support/Cybokron/DockGroups/groups.json`. Of particular interest are issues
that let another process or a crafted `groups.json` launch unintended apps or run code.
