# Security Policy

## Supported versions

Cybokron Dock Groups is in early development. Security fixes are made on the `main` branch and
included in the next release; only the latest release is supported. Releases from v0.6.3 on are
Developer ID signed and notarized. Copies signed ad hoc (v0.6.2 and earlier) can't tell who signed
an update, so they accept any update with an intact signature; once a Developer ID release is
installed, updates must be signed with the same team's Developer ID.

## Reporting a vulnerability

Please **do not** open a public issue for security problems.

Report privately through GitHub:
[Security → Report a vulnerability](https://github.com/ercanatay/cybokron-dock-groups/security/advisories/new).

Include what you found, steps to reproduce, the affected version and macOS version, and the
impact you expect. You can expect an initial reply within a few days. Once a fix is available,
the advisory will be published and you'll be credited unless you prefer otherwise.

## Scope

The app runs locally and stores its data in `~/Library/Application Support/Cybokron/DockGroups/`.
Its only network traffic is over HTTPS to GitHub: unauthenticated GET requests to
`api.github.com` (update checks, Other Versions…, Settings → Changelog; answers redirected
elsewhere are refused) and the download of a release's disk image, which is checked against its
published size and SHA-256 and, on a Developer ID signed copy, against the team's Developer ID
signature before it's mounted and again on the app inside. Nothing about you or your groups is
sent. Other apps and web pages can send it commands through its URL scheme
(`cybokrondockgroups://`): quitting asks first, and opening, hiding, starting or finishing groups
is rate limited; a start or finish link that would quit apps asks first too (or hides them
instead), and protected apps are never quit by Close All, Start or Finish, whoever asks. An app
chosen to open an item is kept by bundle identifier only and checked each time it's used: it must
be an app macOS lists for the item that doesn't run what it opens (Terminal and iTerm2 only for
folders, and never from a backup); otherwise the item isn't opened. A group's keyboard shortcut is a
hot key the app takes only while it runs, and only a key press acts on it; keys that typing, editing
or macOS need (fewer than two of ⌃, ⌥ and ⌘; Escape, Return, Tab, Space, Delete; macOS's own
shortcuts) are refused wherever they come from, so a groups file or backup can't take ⌘C or ⌘Q,
and starting or finishing a group from one asks before quitting apps.

Of particular interest are issues that let another process, a web page or link, a crafted
`groups.json` or `.dockgroups` backup, or a tampered update launch unintended apps or run code.
