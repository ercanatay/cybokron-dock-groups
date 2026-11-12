# Launch actions: the approval record (D9) and standalone groups (D11)

Status: done. Closes the two open items of E phase 2 in the
[launch actions threat model](launch-actions-threat-model.md#10-open-decisions-effort-and-slice-order):

- **D9, approval record.** An action that's on runs only when a separate local file,
  `launch-action-approvals.json`, has the digest of exactly that action for exactly that item.
  Turning the action on in the group window writes the digest; nothing else does.
- **D11, standalone groups.** A group's own app carries its items' actions and runs one for its
  own click, with the same checks as the app and the same approval file.

No new permission, entitlement, localization key, `formatVersion` (groups file, agent
configuration) or backup `schemaVersion`. No new user-visible text: an unapproved action is shown
and refused like one that needs review.

## The file

`~/Library/Application Support/Cybokron/DockGroups/launch-action-approvals.json`, next to
`groups.json` (`LaunchActionApprovalStore.defaultFileURL`, `.onThisMac`). Standalone groups'
apps aren't sandboxed and read the same folder, so the main app and every agent share it. Written
atomically (`JSONFileSupport.write`); removed when the last approval goes.

```json
{
  "approvals" : [
    { "digest" : "<64 lowercase hex digits>", "item" : "https://github.com/cybokron" }
  ],
  "formatVersion" : 1
}
```

- `item` is the item's identity as the store compares it (`normalizedBundleIdentifier`).
- An item can have several records (the same website in two groups with different profiles); a
  record counts only for the item **and** digest it names.
- Read strictly: `formatVersion` must be `1`; a missing, unreadable or newer file approves nothing.
  A record that isn't an object with exactly a non-empty lowercase string `item` and a well-formed
  `digest` is skipped.
- Not part of backups; never read by the backup, template, trigger or link code.

### Digest

SHA-256 of a canonical text, hex lowercase (`LaunchActionApprovalDigest`):

```text
cybokron-dock-groups/launch-action-approval/1
item=27:https://github.com/cybokron
kind=7:website
url=27:https://github.com/cybokron
template=14:browserProfile
browser=6:chrome
profile=4:Work
opener=0:
```

One field per line, `name=<UTF-8 length>:<value>`, fixed order, so no value can be read as another
field. Fields: item identity, item kind, the address it opens (`websiteURL.absoluteString`), the
template ID, the browser family, the profile name, the item's Open With app (lowercased; empty
after Turn On, which drops it). The group isn't part of it: the same action on the same item is the
same approval wherever the item is (a copy of the group, a moved item, an archived group). The name,
details and delay aren't either: they don't change what opens. Only an action that's on and valid
for the item has a digest.

## Rules

| Event | Approval file | Item |
| --- | --- | --- |
| Turn On / Done with a confirmed action in the editor (`GroupStore.updateItem(… .enable)`) | digest written **before** the groups are saved | `enabled`, runs |
| Writing the approval fails | unchanged | shown under review (`requiringApproval`), store issue "Your changes couldn't be saved" |
| Action changed (browser, profile, address, Open With) and confirmed | new digest written, old one dropped | `enabled`, runs |
| Toggle off, item removed, group deleted (active or archived) | digest dropped when no item uses it any more | — |
| Group duplicated, item moved, group archived/restored | kept (same digest) | unchanged |
| Groups file loaded with an `enabled` action whose digest isn't here (another Mac, a recipe, by hand, a file from before this version) | — | read as `review/imported`: the row warns, the editor offers Turn On; written so on the next save |
| An action turned on in code without the editor (`updateGroup`) | — | `review/imported` on the next save |
| Backup restore (Replace All) | approvals of the replaced groups dropped | every action `review/imported` (D4, unchanged) |
| Backup merge | local approvals kept, none added | added actions `review/imported` |
| Group from an imported template | — | `review/imported` |
| Approval file deleted or edited while the app runs | — | not opened at the next launch (read at every launch); the row updates after a restart |

The store (`GroupStore`, with `approvals: .onThisMac` in the app) applies the rule at load, on every
write and on restore/merge; the launcher applies it again at launch time, reading the file each
time. A store without approvals (tests, the agent's read-only copy) neither records nor drops any
and leaves actions as the file has them; a launcher without approvals runs no action.

### Launcher order

For an item with an action, `GroupLauncher.openWithLaunchAction` checks, first failure wins:

1. Source user-present (`userAction`, `standaloneAgent`) → else `source.<source>`.
2. The workspace can run actions → else `noRunner`.
3. Plan (`LaunchActionArgumentPlan.make`): enabled, valid, kind, address, browser family,
   installed → else `plan.<reason>` (an imported/unapproved action is `plan.actionDisabled`).
4. **Approval**: the file has `(item, digest)` → else `approval.missing` (no record for the item)
   or `approval.mismatch` (records for the item, none with this digest).
5. Runner: installed bundle, not running, start → else `run.<reason>`.

Every refusal opens nothing (D5) and is reported with the existing "The app wasn't opened." text;
the log has the fixed code only.

## Standalone groups (D11)

- `AgentConfiguration` keeps the group's actions as they are, status included (it used to drop them
  on write and read). An agent configuration built by the main app holds what the main store has:
  unapproved actions are already under review there.
- `LaunchSource.standaloneAgent` is user-present: the agent opens items only from its popup, its
  Dock menu and ⌥-clicking its tile, all the user's own clicks. Links, Siri, Focus, triggers,
  shortcuts and the CLI stay unattended.
- The agent's launcher gets `approvals: .onThisMac`, so it checks grammar, browser set, address,
  installation, running state **and** the digest exactly like the main app. An action in a
  configuration file written by hand or copied with the bundle has no approval → not opened at all,
  reported with the existing text, logged as `approval.missing` / `approval.mismatch`.
- The agent's own store is a read-only copy (`FixedGroupPersistence`, no approvals): it never
  writes or prunes the approval file.

## Upgrading from 0.18.0

0.18.0 kept no approvals. After updating, a browser profile turned on in 0.18.0 has no digest, so it
is shown as needing review and doesn't open until it's turned on again (one Turn On per item). This
is the fail-closed choice: approving every existing `enabled` action automatically would also
approve one written into the file by hand or by another app. An older version reading the files
ignores `launch-action-approvals.json` and runs `enabled` actions as before (it can't know the
file); its saves keep the file intact.

## Accepted risk

- **Same-user writer.** Anyone who can write `groups.json` (or an agent's configuration) as the user
  can also write `launch-action-approvals.json`, computing the digest from this document. The file
  isn't a signature (no Keychain HMAC, already rejected: threat model T8/D9). What it stops is an
  approval that arrives **by accident or by copying**: a groups file or configuration from another
  Mac, a recipe, a sync tool, a backup. A writer of both files could already install a LaunchAgent.
  `LaunchActionReviewPersistenceTests.aStatusEditedByHandRunsOnlyWithItsApproval` records it.
- **An approval in the file without a matching item** is inert and dropped on the next write.
- **The same action on the same item in two groups** shares one approval; turning it off in one keeps
  the other's (the record stays while any item uses it).
- **A newer version's file** (`formatVersion` > 1) approves nothing here, and turning an action on
  replaces it with a version-1 file.
- **The window's state is a snapshot**: the file is read for the rows at load and on every write; a
  record deleted by hand meanwhile refuses the launch at once but the row updates after the next
  write or restart.

## Code and tests

- `Sources/DockGroupsCore/LaunchActions/LaunchActionApprovals.swift`: `LaunchActionApproval(s)`,
  `LaunchActionApprovalDigest`, `LaunchActionApprovalStore` (file / memory), the document coding,
  `LaunchActionApprovalCheck`, `LaunchActionApprovalRefusal`.
- `GroupStore`: `approvals:` init parameter; `requiringApproval` at load, write, restore/merge;
  `approve` in `updateItem(… .enable)`; `pruneApprovals` after writes.
- `GroupLauncher`: `approvals:` init parameter; step 4 above. `LaunchActionItemRefusal.approval`.
- `LaunchSource.isUserPresent` includes `standaloneAgent`. `AgentConfiguration` keeps actions.
- App: `AppDelegate` (store and launcher) and `AgentAppDelegate` (launcher) pass `.onThisMac`.
- `Tests/DockGroupsCoreTests/LaunchActionApprovalTests.swift`: canonical text and digest, every field
  changes it; approved runs, missing file / mismatch (profile, browser, address) / unreadable or
  newer file / malformed records don't; read at every launch; Turn On writes and toggling off removes;
  changing the profile replaces it; removing the item or group removes it; copies and archives keep
  it; a groups file from elsewhere is under review until Turn On; turned on in code → review; a failed
  write keeps it under review; restore, merge, imported template bring none; the agent path through
  `AgentConfiguration` (approved runs with `.standaloneAgent`, unapproved and hand-edited don't, the
  same checks as the app); the shared path.
- Changed tests (each says why): `LaunchActionRunnerTests` / `SwitchingFakes` give the launcher
  approvals where an action must reach the runner, and `standaloneAgent` is user-present;
  `LaunchActionReviewPersistenceTests` use a real approval file (a hand-edited status needs its
  approval too); `LaunchActionEditingTests.anImportedItemOpensOnlyOnceTurnedOn` shares the
  approvals between store and launcher; `LaunchActionBackupTests.agentsCarryTheirLaunchActions`
  replaces `agentsCarryNoLaunchAction`; the source scans allow the new file and check that both
  apps pass `.onThisMac`; `LaunchOptionsWiringTests` expects the new launcher line.
