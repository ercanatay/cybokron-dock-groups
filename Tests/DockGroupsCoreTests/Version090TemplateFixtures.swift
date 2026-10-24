import Foundation
@testable import DockGroupsCore

/// A templates file and a backup with a template, as this version writes them, and the backup as
/// version 0.8.0 (`8127967`) saved it again after importing it: that build read the backup's
/// groups and ignored its `templates` list, which it dropped when saving. 0.8.0 never opens
/// `templates.json`.
enum Version090TemplateFixtures {
    /// Coding — standalone, with a shortcut — saved as "Coding Starter".
    static var template: GroupTemplate {
        GroupTemplate(
            saving: Version080Fixtures.groupsWithShortcuts[0],
            named: "Coding Starter",
            id: UUID(uuidString: "7E3A1A7E-0000-4000-8000-000000000090")!,
            at: Date(timeIntervalSince1970: 1_793_300_000)
        )
    }

    /// `templates.json` with `template`.
    static let templatesFile = #"""
{
  "formatVersion" : 1,
  "templates" : [
    {
      "group" : {
        "apps" : [
          {
            "bundleIdentifier" : "com.apple.dt.Xcode",
            "name" : "Xcode",
            "path" : "/Applications/Xcode.app",
            "tags" : [
              "dev"
            ]
          },
          {
            "bundleIdentifier" : "com.tinyspeck.slackmacgap",
            "launchDelay" : 5,
            "name" : "Slack"
          },
          {
            "bundleIdentifier" : "file:///Users/me/Projects/cybokron/",
            "kind" : "folder",
            "name" : "cybokron",
            "openWith" : {
              "bundleIdentifier" : "com.microsoft.VSCode",
              "name" : "Visual Studio Code"
            }
          },
          {
            "alias" : "Quarterly report",
            "bundleIdentifier" : "file:///Users/me/Documents/Q3%20Report.pdf",
            "kind" : "file",
            "launchDelay" : 3,
            "name" : "Q3 Report.pdf",
            "notes" : "Send totals\non Fridays",
            "openWith" : {
              "bundleIdentifier" : "com.apple.Preview",
              "name" : "Preview"
            },
            "tags" : [
              "finance",
              "q3"
            ]
          },
          {
            "bundleIdentifier" : "https://github.com/cybokron",
            "kind" : "website",
            "name" : "Cybokron",
            "url" : "https://github.com/cybokron"
          }
        ],
        "emoji" : "💻",
        "freeLayoutSlots" : {
          "com.apple.dt.xcode" : 0,
          "file:///users/me/projects/cybokron/" : 2
        },
        "id" : "7E3A1A7E-0000-4000-8000-000000000090",
        "isPinned" : true,
        "isStandalone" : false,
        "name" : "Coding Starter",
        "popup" : {
          "columns" : 4,
          "maxRows" : 2
        },
        "switching" : {
          "afterFinish" : "nothing",
          "onFinish" : "hideApps",
          "onStart" : "quitPreviousGroup"
        },
        "tile" : {
          "backgroundColor" : "#2F6FEB",
          "backgroundStyle" : "solid",
          "kind" : "grid"
        }
      },
      "id" : "7E3A1A7E-0000-4000-8000-000000000090",
      "savedAt" : "2026-10-29T18:53:20Z"
    }
  ]
}
"""#

    /// A backup of Design, `template` and `Version080Fixtures.preferences`, exported at
    /// `Version080Fixtures.exportedAt` by this version.
    static let backup = #"""
{
  "app" : "cybokron-dock-groups",
  "appVersion" : "0.9.0",
  "exportedAt" : "2026-10-27T11:20:00Z",
  "groups" : [
    {
      "apps" : [
        {
          "bundleIdentifier" : "com.figma.Desktop",
          "name" : "Figma"
        }
      ],
      "emoji" : "🎨",
      "id" : "0DE51600-0000-4000-8000-000000000080",
      "isPinned" : false,
      "isStandalone" : false,
      "name" : "Design",
      "popup" : {

      },
      "tile" : {
        "backgroundColor" : "#2F6FEB",
        "backgroundStyle" : "solid",
        "kind" : "emoji"
      }
    }
  ],
  "preferences" : {
    "automaticallyChecksForUpdates" : false,
    "formatVersion" : 1,
    "freeLayout" : true,
    "glassyStyle" : false,
    "globalShortcutModifiers" : "controlCommand",
    "globalShortcutsEnabled" : true,
    "language" : "tr",
    "mostUsedLimit" : 5,
    "mostUsedSessionSeconds" : 900,
    "panelTheme" : "light",
    "popupAnchor" : "dockIcon",
    "popupColumns" : 5,
    "popupMaxRows" : 3,
    "popupShowsMostUsed" : false,
    "popupShowsTitles" : false,
    "protectedApps" : [
      {
        "bundleIdentifier" : "com.apple.Music",
        "name" : "Music"
      }
    ],
    "restoreRunningAppWindows" : false,
    "standaloneDockMenu" : false
  },
  "schemaVersion" : 1,
  "templates" : [
    {
      "group" : {
        "apps" : [
          {
            "bundleIdentifier" : "com.apple.dt.Xcode",
            "name" : "Xcode",
            "path" : "/Applications/Xcode.app",
            "tags" : [
              "dev"
            ]
          },
          {
            "bundleIdentifier" : "com.tinyspeck.slackmacgap",
            "launchDelay" : 5,
            "name" : "Slack"
          },
          {
            "bundleIdentifier" : "file:///Users/me/Projects/cybokron/",
            "kind" : "folder",
            "name" : "cybokron",
            "openWith" : {
              "bundleIdentifier" : "com.microsoft.VSCode",
              "name" : "Visual Studio Code"
            }
          },
          {
            "alias" : "Quarterly report",
            "bundleIdentifier" : "file:///Users/me/Documents/Q3%20Report.pdf",
            "kind" : "file",
            "launchDelay" : 3,
            "name" : "Q3 Report.pdf",
            "notes" : "Send totals\non Fridays",
            "openWith" : {
              "bundleIdentifier" : "com.apple.Preview",
              "name" : "Preview"
            },
            "tags" : [
              "finance",
              "q3"
            ]
          },
          {
            "bundleIdentifier" : "https://github.com/cybokron",
            "kind" : "website",
            "name" : "Cybokron",
            "url" : "https://github.com/cybokron"
          }
        ],
        "emoji" : "💻",
        "freeLayoutSlots" : {
          "com.apple.dt.xcode" : 0,
          "file:///users/me/projects/cybokron/" : 2
        },
        "id" : "7E3A1A7E-0000-4000-8000-000000000090",
        "isPinned" : true,
        "isStandalone" : false,
        "name" : "Coding Starter",
        "popup" : {
          "columns" : 4,
          "maxRows" : 2
        },
        "switching" : {
          "afterFinish" : "nothing",
          "onFinish" : "hideApps",
          "onStart" : "quitPreviousGroup"
        },
        "tile" : {
          "backgroundColor" : "#2F6FEB",
          "backgroundStyle" : "solid",
          "kind" : "grid"
        }
      },
      "id" : "7E3A1A7E-0000-4000-8000-000000000090",
      "savedAt" : "2026-10-29T18:53:20Z"
    }
  ]
}
"""#

    /// `backup` imported and saved again by 0.8.0.
    static let backupSavedBy080 = #"""
{
  "app" : "cybokron-dock-groups",
  "appVersion" : "0.9.0",
  "exportedAt" : "2026-10-27T11:20:00Z",
  "groups" : [
    {
      "apps" : [
        {
          "bundleIdentifier" : "com.figma.Desktop",
          "name" : "Figma"
        }
      ],
      "emoji" : "🎨",
      "id" : "0DE51600-0000-4000-8000-000000000080",
      "isPinned" : false,
      "isStandalone" : false,
      "name" : "Design",
      "popup" : {

      },
      "tile" : {
        "backgroundColor" : "#2F6FEB",
        "backgroundStyle" : "solid",
        "kind" : "emoji"
      }
    }
  ],
  "preferences" : {
    "automaticallyChecksForUpdates" : false,
    "formatVersion" : 1,
    "freeLayout" : true,
    "glassyStyle" : false,
    "globalShortcutModifiers" : "controlCommand",
    "globalShortcutsEnabled" : true,
    "language" : "tr",
    "mostUsedLimit" : 5,
    "mostUsedSessionSeconds" : 900,
    "panelTheme" : "light",
    "popupAnchor" : "dockIcon",
    "popupColumns" : 5,
    "popupMaxRows" : 3,
    "popupShowsMostUsed" : false,
    "popupShowsTitles" : false,
    "protectedApps" : [
      {
        "bundleIdentifier" : "com.apple.Music",
        "name" : "Music"
      }
    ],
    "restoreRunningAppWindows" : false,
    "standaloneDockMenu" : false
  },
  "schemaVersion" : 1
}
"""#
}
