import Foundation
import Security

/// Unused experimental synchronous primitive for extracting a static code hash
/// from an application bundle. This does not authenticate the publisher,
/// check the running process, make file checks race-free, or provide async
/// execution. No caching, persistence, or logging is performed.
internal enum ApplicationStaticCodeVerifier {
    /// This reads only the Security framework default slice; it is insufficient for universal apps and must not be used to authorize a trigger.
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

    /// UNUSED EXPERIMENTAL — synchronous only; does not establish path/symlink
    /// race safety, process identity, publisher trust, or local authorization,
    /// and is NOT used in app triggers.
    static func codeHashes(for appURL: URL) -> [ApplicationCodeHash]? {
        // Fail closed on any error; filesystem operations use do/catch.
        do {
            guard appURL.isFileURL else { return nil }
            guard appURL.pathExtension.lowercased() == "app" else { return nil }
            if let host = appURL.host, !host.isEmpty, host != "localhost" { return nil }

            let resolvedBundle = appURL.resolvingSymlinksInPath().standardizedFileURL
            guard let bundle = Bundle(url: resolvedBundle) else { return nil }
            guard let executableURL = bundle.executableURL else { return nil }
            let resolvedExec = executableURL.resolvingSymlinksInPath().standardizedFileURL

            let expectedComponents = resolvedBundle.pathComponents + ["Contents", "MacOS"]
            let macosDir = resolvedBundle
                .appendingPathComponent("Contents")
                .appendingPathComponent("MacOS")
                .resolvingSymlinksInPath()
                .standardizedFileURL
            guard macosDir.pathComponents == expectedComponents else { return nil }
            let macosAttrs = try FileManager.default.attributesOfItem(atPath: macosDir.path)
            guard let macosType = macosAttrs[.type] as? FileAttributeType,
                  macosType == .typeDirectory else { return nil }
            let execParent = resolvedExec.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            guard execParent.path == macosDir.path else { return nil }

            let resourceValues = try resolvedExec.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard resourceValues.isRegularFile == true else { return nil }
            guard let fileSizeValue = resourceValues.fileSize else { return nil }
            guard fileSizeValue >= 0 else { return nil }
            let fileSize = UInt64(fileSizeValue)

            let handle = try FileHandle(forReadingFrom: resolvedExec)
            defer { try? handle.close() }
            guard let prefix = try handle.read(upToCount: 520) else { return nil }
            guard let slices = MachOSliceTable.parse(prefix: prefix, fileSize: fileSize) else { return nil }

            var results: [ApplicationCodeHash] = []
            var seen = Set<ApplicationCodeHash>()
            for slice in slices {
                guard slice.offset <= UInt64(Int64.max) else { return nil }
                var code: SecStaticCode?
                let attrs: [String: Any] = [kSecCodeAttributeUniversalFileOffset as String: NSNumber(value: Int64(slice.offset))]
                let createStatus = SecStaticCodeCreateWithPathAndAttributes(
                    resolvedBundle as CFURL,
                    SecCSFlags(),
                    attrs as CFDictionary,
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
                      data.count == 20 else { return nil }
                guard let hash = ApplicationCodeHash(bytes: Array(data)) else { return nil }
                if !seen.contains(hash) {
                    seen.insert(hash)
                    results.append(hash)
                }
            }
            guard !results.isEmpty else { return nil }
            return results
        } catch {
            return nil
        }
    }
}
