import Foundation

/// Release JSON shaped like GitHub's `GET /repos/{owner}/{repo}/releases/latest` answer (trimmed),
/// so the updater's tests run without a network.
enum ReleaseFixtures {
    /// The v0.5.0 release as GitHub returned it, with its DMG and its checksum.
    static let v050 = """
    {
      "url": "https://api.github.com/repos/ercanatay/cybokron-dock-groups/releases/415816650",
      "html_url": "https://github.com/ercanatay/cybokron-dock-groups/releases/tag/v0.5.0",
      "id": 415816650,
      "tag_name": "v0.5.0",
      "target_commitish": "main",
      "name": "v0.5.0",
      "draft": false,
      "immutable": false,
      "prerelease": false,
      "created_at": "2026-10-17T13:21:20Z",
      "published_at": "2026-10-17T13:24:51Z",
      "assets": [
        {
          "url": "https://api.github.com/repos/ercanatay/cybokron-dock-groups/releases/assets/650531464",
          "id": 650531464,
          "name": "Cybokron-Dock-Groups-0.5.0-universal.dmg",
          "label": "",
          "content_type": "application/x-apple-diskimage",
          "state": "uploaded",
          "size": 2529600,
          "digest": "sha256:3fd7bbe8309e72b987f705e34d9ebdd31f4e8c430de419abc2c2682457a89717",
          "download_count": 0,
          "browser_download_url": "https://github.com/ercanatay/cybokron-dock-groups/releases/download/v0.5.0/Cybokron-Dock-Groups-0.5.0-universal.dmg"
        }
      ],
      "tarball_url": "https://api.github.com/repos/ercanatay/cybokron-dock-groups/tarball/v0.5.0",
      "zipball_url": "https://api.github.com/repos/ercanatay/cybokron-dock-groups/zipball/v0.5.0",
      "body": "**Full Changelog**: https://github.com/ercanatay/cybokron-dock-groups/commits/v0.5.0"
    }
    """

    /// A newer release whose assets list decoys before the universal DMG: a zip, a per-architecture
    /// DMG, a checksum file named after the DMG, and an asset that is still uploading.
    static let v060WithDecoys = """
    {
      "html_url": "https://github.com/ercanatay/cybokron-dock-groups/releases/tag/v0.6.0",
      "tag_name": "v0.6.0",
      "name": "Cybokron Dock Groups 0.6.0",
      "draft": false,
      "prerelease": false,
      "published_at": "2026-11-01T09:00:00Z",
      "body": "## What's new\\n- Faster popups\\n- Bug fixes",
      "assets": [
        {"name": "Cybokron-Dock-Groups.zip", "state": "uploaded", "size": 100,
         "browser_download_url": "https://example.com/Cybokron-Dock-Groups.zip"},
        {"name": "Cybokron-Dock-Groups-0.6.0-arm64.dmg", "state": "uploaded", "size": 100,
         "browser_download_url": "https://example.com/Cybokron-Dock-Groups-0.6.0-arm64.dmg"},
        {"name": "Cybokron-Dock-Groups-0.6.0-universal.dmg.sha256", "state": "uploaded", "size": 64,
         "browser_download_url": "https://example.com/Cybokron-Dock-Groups-0.6.0-universal.dmg.sha256"},
        {"name": "Cybokron-Dock-Groups-0.6.0-universal.dmg", "state": "starter", "size": 0,
         "browser_download_url": "https://example.com/uploading/Cybokron-Dock-Groups-0.6.0-universal.dmg"},
        {"name": "Cybokron-Dock-Groups-0.6.0-universal.dmg", "state": "uploaded", "size": 2600000,
         "browser_download_url": "https://example.com/Cybokron-Dock-Groups-0.6.0-universal.dmg"}
      ]
    }
    """

    /// A newer release with only a zip attached.
    static let v060WithoutDMG = """
    {
      "tag_name": "0.6.0",
      "html_url": "https://github.com/ercanatay/cybokron-dock-groups/releases/tag/0.6.0",
      "body": null,
      "assets": [
        {"name": "Cybokron-Dock-Groups.zip", "state": "uploaded", "size": 100,
         "browser_download_url": "https://example.com/Cybokron-Dock-Groups.zip"}
      ]
    }
    """

    static func data(_ json: String) -> Data {
        Data(json.utf8)
    }
}
