import Foundation
import Security

/// Unused experimental synchronous primitive for extracting a static code hash
/// from an application bundle. This does not authenticate the publisher,
/// check the running process, make file checks race-free, or provide async
/// execution. No caching, persistence, or logging is performed.
internal enum ApplicationStaticCodeVerifier {
    static func codeHash(for appURL: URL) -> ApplicationCodeHash? {
        guard appURL.isFileURL else { return nil }
        guard appURL.pathExtension.lowercased() == "app" else { return nil }

        var code: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            appURL as CFURL,
            SecCSFlags(),
            &code
        )
        guard createStatus == errSecSuccess, let staticCode = code else { return nil }

        let validityStatus = SecStaticCodeCheckValidity(staticCode, SecCSFlags(), nil)
        guard validityStatus == errSecSuccess else { return nil }

        var info: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &info
        )
        guard infoStatus == errSecSuccess,
              let dict = info as? [String: Any],
              let data = dict[kSecCodeInfoUnique as String] as? Data,
              data.count == 20 else {
            return nil
        }

        return ApplicationCodeHash(bytes: Array(data))
    }
}
