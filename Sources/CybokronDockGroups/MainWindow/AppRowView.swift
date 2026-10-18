import AppKit
import DockGroupsCore
import SwiftUI

/// One member app: icon, name, bundle identifier (or location, for an app without one), and a
/// button that removes it from the group.
struct AppRowView: View {
    let app: AppReference
    let onRemove: () -> Void

    var body: some View {
        let location = app.resolvedURL()
        HStack(spacing: 10) {
            Image(nsImage: icon(at: location))
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .lineLimit(1)
                Group {
                    if location == nil {
                        Text("Not found on this Mac · \(identity)")
                            .foregroundStyle(.orange)
                    } else {
                        Text(identity)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove \(app.name) from this group. The app itself isn't affected.")
        }
        .padding(.vertical, 2)
    }

    /// The bundle identifier, or the app's location (as `~/…`) when it has none.
    private var identity: String {
        app.isIdentifiedByPath ? (app.bundleIdentifier as NSString).abbreviatingWithTildeInPath : app.bundleIdentifier
    }

    private func icon(at location: URL?) -> NSImage {
        guard let location else { return NSWorkspace.shared.icon(for: .applicationBundle) }
        return NSWorkspace.shared.icon(forFile: location.path)
    }
}
