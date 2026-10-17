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

    /// The group `token` names: a group identifier (UUID) first, then a name with the same slug —
    /// so case, accents, spaces and punctuation don't matter — and for names without letters or
    /// digits the exact name. The first match in list order wins.
    public static func group(matching token: String, in groups: [DockGroup]) -> DockGroup? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let id = UUID(uuidString: trimmed), let group = groups.first(where: { $0.id == id }) {
            return group
        }
        let wanted = slug(for: trimmed)
        if !wanted.isEmpty {
            return groups.first { slug(for: $0.name) == wanted }
        }
        return groups.first { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed }
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
