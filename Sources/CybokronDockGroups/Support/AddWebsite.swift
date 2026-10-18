import AppKit
import DockGroupsCore
import SwiftUI

/// Asks for a website to add to a group: its address ("https://" is added when it's left out) and
/// an optional name, the host by default. Problems show below the fields; the sheet stays open
/// until a website is added or the user cancels.
struct AddWebsiteView: View {
    let groupName: String
    /// Adds the website to the group; returns `false` when the group already has it.
    let add: (AppReference) -> Bool
    let dismiss: () -> Void

    @State private var address = ""
    @State private var name = ""
    @State private var problem: String?
    @FocusState private var isAddressFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Website to “\(groupName)”")
                .font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Address:")
                        .gridColumnAlignment(.trailing)
                    TextField("https://example.com", text: $address)
                        .textFieldStyle(.roundedBorder)
                        .focused($isAddressFocused)
                        .accessibilityLabel("Website address")
                }
                GridRow {
                    Text("Name:")
                    TextField(namePlaceholder, text: $name)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Website name, optional")
                }
            }
            Group {
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                } else {
                    Text("Opens in your default browser. Leave the name empty to use the site's address.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { isAddressFocused = true }
        .onChange(of: address) { problem = nil }
    }

    /// The name the website gets when the field is left empty.
    private var namePlaceholder: String {
        (try? WebsiteAddress.parse(address)).map(WebsiteAddress.defaultName(for:)) ?? "Optional"
    }

    private func submit() {
        do {
            let website = AppReference(websiteURL: try WebsiteAddress.parse(address), name: name)
            if add(website) {
                dismiss()
            } else {
                problem = "“\(website.websiteURL?.absoluteString ?? website.name)” is already in this group."
            }
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// A small window with `AddWebsiteView`, for adding a website from a popup (which has no room for
/// a sheet). One at a time: asking again replaces its group.
@MainActor
final class AddWebsiteWindowController {
    private let store: GroupStore
    private var window: NSWindow?

    init(store: GroupStore) {
        self.store = store
    }

    func show(for group: DockGroup) {
        let groupID = group.id
        let view = AddWebsiteView(
            groupName: group.name,
            add: { [weak self] website in
                (self?.store.addApps([website], toGroup: groupID) ?? 0) > 0
            },
            dismiss: { [weak self] in self?.window?.close() }
        )
        let window = self.window ?? makeWindow()
        // A fresh view each time, so the fields start empty.
        window.contentViewController = NSHostingController(rootView: view)
        window.title = "Add Website"
        self.window = window
        NSApp.activate()
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        return window
    }
}
