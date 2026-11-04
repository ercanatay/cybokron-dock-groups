import Foundation

/// Constructs a syntax-only application presence requirement expression.
/// This validates syntax only; it does not verify trust, authorization,
/// or that the hash corresponds to any real application. It does not
/// grant trust or authorize an app.
internal enum ApplicationCodeRequirement {
    static func expression(bundleIdentifier: String, codeHash: ApplicationCodeHash) -> String? {
        guard let identifier = TriggerApplicationIdentifier(bundleIdentifier) else {
            return nil
        }
        return "identifier \"\(identifier.rawValue)\" and \(codeHash.requirementExpression)"
    }
}
