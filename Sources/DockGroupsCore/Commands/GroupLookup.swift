import Foundation

/// Finds groups by the names people type or say: in URLs, Siri and the Shortcuts app.
public enum GroupLookup {
    /// ICU transform that spells any script in plain lowercase ASCII ("Çalışma" → "calisma").
    private static let asciiTransform = StringTransform("Any-Latin; Latin-ASCII; Any-Lower")

    /// The URL-friendly form of a group name: lowercase ASCII letters and digits, with single
    /// hyphens between words ("Çalışma Alanı" → "calisma-alani", "Dev & Ops!" → "dev-ops"). Empty
    /// for names without letters or digits, such as a lone emoji.
    public static func slug(for name: String) -> String {
        let ascii = (name.applyingTransform(asciiTransform, reverse: false) ?? name).lowercased()
        var slug = ""
        var needsHyphen = false
        for scalar in ascii.unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                if needsHyphen, !slug.isEmpty {
                    slug += "-"
                }
                needsHyphen = false
                slug.unicodeScalars.append(scalar)
            } else {
                needsHyphen = true
            }
        }
        return slug
    }

    /// The group `token` names, or `nil` when `resolve` finds none or more than one.
    public static func group(matching token: String, in groups: [DockGroup]) -> DockGroup? {
        resolve(token, in: groups).group
    }

    /// What `token` names among `groups`. A group identifier (UUID) names only the group with that
    /// identifier: when no group has it, no name is tried — a renamed group keeps its links, and a
    /// deleted one's links never open another group. Any other token is a name, matched by slug —
    /// so case, accents, spaces and punctuation don't matter — and for names without letters or
    /// digits exactly; when more than one group answers to it, none is chosen.
    public static func resolve(_ token: String, in groups: [DockGroup]) -> GroupResolution {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .notFound }
        if let id = UUID(uuidString: trimmed) {
            return groups.first { $0.id == id }.map(GroupResolution.found) ?? .notFound
        }
        let wanted = slug(for: trimmed)
        let matches = wanted.isEmpty
            ? groups.filter { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed }
            : groups.filter { slug(for: $0.name) == wanted }
        switch matches.count {
        case 0: return .notFound
        case 1: return .found(matches[0])
        default: return .ambiguous(name: trimmed, matches: matches.map(\.id))
        }
    }

    /// The groups whose names contain `text`, ignoring case, accents and punctuation, in list order.
    /// Blank text matches every group.
    public static func search(_ text: String, in groups: [DockGroup]) -> [DockGroup] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return groups }
        let wanted = slug(for: trimmed)
        return groups.filter { group in
            if group.name.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                return true
            }
            return !wanted.isEmpty && slug(for: group.name).contains(wanted)
        }
    }

    /// A normalized form of `token` for comparing requests: its slug, or the trimmed token itself
    /// when it has no letters or digits.
    public static func normalizedToken(_ token: String) -> String {
        let slug = slug(for: token)
        return slug.isEmpty ? token.trimmingCharacters(in: .whitespacesAndNewlines) : slug
    }
}

/// What a link's group token finds (`GroupLookup.resolve`).
public enum GroupResolution: Equatable, Sendable {
    case found(DockGroup)
    /// No group: an identifier no group has, or a name no group answers to.
    case notFound
    /// More than one group answers to `name` (`matches`, in list order): none is chosen.
    case ambiguous(name: String, matches: [DockGroup.ID])

    /// The group found; `nil` when none or more than one is.
    public var group: DockGroup? {
        if case .found(let group) = self { return group }
        return nil
    }

    /// What to tell the user about a link whose group wasn't found; `nil` when it was.
    public var problemMessage: String? {
        switch self {
        case .found:
            return nil
        case .notFound:
            return Localization.string(
                "core.link.groupNotFound",
                "The group this link opens doesn't exist anymore. It may have been deleted or archived, or renamed if the link names it by name."
            )
        case .ambiguous(let name, _):
            return Localization.format(
                "core.link.groupAmbiguous",
                "More than one group is named “%@”, so the link didn't open any of them. Copy the group's link again from Settings → Shortcuts & Siri.",
                name
            )
        }
    }
}
