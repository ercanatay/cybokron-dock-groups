import Foundation
@testable import DockGroupsCore

/// A groups file and a backup with an archived group, as this version writes them, and as version
/// 0.8.0 (`8127967`) saved them again after reading them. Design is active; Coding — standalone,
/// with a shortcut — is archived. That build of 0.8.0 read both files as two ordinary groups,
/// Coding not standalone (so 0.8.0 never turns it off for lacking a Dock tile, and a store loading
/// the file left it byte for byte as it was); saving them dropped only the archive marks and the
/// shortcuts.
enum Version090ArchiveFixtures {
    static let archivedAt = Date(timeIntervalSince1970: 1_793_200_000)

    static var stored: StoredGroups {
        let groups = Version080Fixtures.groupsWithShortcuts
        return StoredGroups(active: [groups[1]], archived: [ArchivedGroup(group: groups[0], archivedAt: archivedAt)])
    }

    /// `groups.json` with `stored`.
    static let groupsFile = #"""
{
  "formatVersion" : 1,
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
      "shortcut" : {
        "action" : "showPopup",
        "keyCode" : 2,
        "modifiers" : [
          "control",
          "option"
        ]
      },
      "tile" : {
        "backgroundColor" : "#2F6FEB",
        "backgroundStyle" : "solid",
        "kind" : "emoji"
      }
    },
    {
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
      "archived" : true,
      "archivedAt" : "2026-10-28T15:06:40Z",
      "emoji" : "💻",
      "freeLayoutSlots" : {
        "com.apple.dt.xcode" : 0,
        "file:///users/me/projects/cybokron/" : 2
      },
      "id" : "0C0D1E00-0000-4000-8000-000000000080",
      "isPinned" : true,
      "isStandalone" : false,
      "name" : "Coding",
      "popup" : {
        "columns" : 4,
        "maxRows" : 2
      },
      "restoresStandalone" : true,
      "shortcut" : {
        "action" : "startOrFinish",
        "keyCode" : 8,
        "modifiers" : [
          "control",
          "option"
        ]
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
    }
  ]
}
"""#

    /// A backup of `stored` and `Version080Fixtures.preferences`, exported at
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
      "shortcut" : {
        "action" : "showPopup",
        "keyCode" : 2,
        "modifiers" : [
          "control",
          "option"
        ]
      },
      "tile" : {
        "backgroundColor" : "#2F6FEB",
        "backgroundStyle" : "solid",
        "kind" : "emoji"
      }
    },
    {
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
      "archived" : true,
      "archivedAt" : "2026-10-28T15:06:40Z",
      "emoji" : "💻",
      "freeLayoutSlots" : {
        "com.apple.dt.xcode" : 0,
        "file:///users/me/projects/cybokron/" : 2
      },
      "id" : "0C0D1E00-0000-4000-8000-000000000080",
      "isPinned" : true,
      "isStandalone" : false,
      "name" : "Coding",
      "popup" : {
        "columns" : 4,
        "maxRows" : 2
      },
      "restoresStandalone" : true,
      "shortcut" : {
        "action" : "startOrFinish",
        "keyCode" : 8,
        "modifiers" : [
          "control",
          "option"
        ]
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

    /// `groupsFile` read and saved again by 0.8.0.
    static let groupsFileSavedBy080 = #"""
{
  "formatVersion" : 1,
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
    },
    {
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
      "id" : "0C0D1E00-0000-4000-8000-000000000080",
      "isPinned" : true,
      "isStandalone" : false,
      "name" : "Coding",
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
    }
  ]
}
"""#

    /// `backup` read and saved again by 0.8.0.
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
    },
    {
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
      "id" : "0C0D1E00-0000-4000-8000-000000000080",
      "isPinned" : true,
      "isStandalone" : false,
      "name" : "Coding",
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
