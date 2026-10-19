import Foundation
import Testing

/// Runs one of the repository's `scripts/` with bash, the GitHub Actions variables the scripts
/// read removed from the environment unless a test sets them.
struct RepositoryScript {
    struct Result {
        let status: Int32
        let output: String
        let errors: String
    }

    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    let name: String

    func run(_ arguments: [String] = [], environment: [String: String] = [:]) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.root.appending(components: "scripts", name).path] + arguments
        var variables = ProcessInfo.processInfo.environment
        for key in ["GITHUB_REF_NAME", "GITHUB_REF_TYPE"] {
            variables.removeValue(forKey: key)
        }
        process.environment = variables.merging(environment) { $1 }
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(
            status: process.terminationStatus,
            output: String(decoding: outputData, as: UTF8.self),
            errors: String(decoding: errorData, as: UTF8.self)
        )
    }
}

/// `scripts/check-version.sh`: the version is the same in build-app.sh, project.yml and both
/// build configurations of project.pbxproj, and a version tag names it.
@Suite("Version check script")
struct CheckVersionScriptTests {
    private let script = RepositoryScript(name: "check-version.sh")

    /// A checkout with only the three files the script reads.
    private func checkout(buildScript: String = "0.7.0", projectYML: String = "0.7.0", pbxproj: [String] = ["0.7.0", "0.7.0"]) throws -> TemporaryDirectory {
        let temporary = try TemporaryDirectory()
        let files: [(String, String)] = [
            ("scripts/build-app.sh", "#!/usr/bin/env bash\nAPP_NAME=\"Cybokron Dock Groups\"\nMARKETING_VERSION=\"\(buildScript)\"\nBUILD_NUMBER=\"1\"\n"),
            ("project.yml", "settings:\n  base:\n    MARKETING_VERSION: \"\(projectYML)\"\n    CURRENT_PROJECT_VERSION: \"1\"\n"),
            ("CybokronDockGroups.xcodeproj/project.pbxproj", pbxproj.map { "\t\t\t\tMARKETING_VERSION = \($0);\n\t\t\t\tPRODUCT_NAME = x;\n" }.joined()),
        ]
        for (path, text) in files {
            let url = temporary.url.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        return temporary
    }

    @Test func theRepositoryIsConsistent() throws {
        let result = try script.run()
        #expect(result.status == 0, "\(result.errors)")
        #expect(result.output.contains("agree"))
    }

    @Test func matchingVersionsAndTagPass() throws {
        let temporary = try checkout()
        defer { temporary.remove() }

        let plain = try script.run([temporary.url.path])
        let tagged = try script.run([temporary.url.path], environment: ["GITHUB_REF_NAME": "v0.7.0", "GITHUB_REF_TYPE": "tag"])
        // Branch and pull request builds have no tag to compare.
        let branch = try script.run([temporary.url.path], environment: ["GITHUB_REF_NAME": "main", "GITHUB_REF_TYPE": "branch"])

        #expect(plain.status == 0 && plain.output.contains("Version 0.7.0"))
        #expect(tagged.status == 0 && tagged.output.contains("Tag v0.7.0 matches"))
        #expect(branch.status == 0)
    }

    @Test func aDifferentProjectYMLVersionFails() throws {
        let temporary = try checkout(projectYML: "0.6.9")
        defer { temporary.remove() }

        let result = try script.run([temporary.url.path])

        #expect(result.status == 1)
        #expect(result.errors.contains("project.yml: MARKETING_VERSION is 0.6.9, scripts/build-app.sh has 0.7.0"))
    }

    @Test func eachBuildConfigurationIsChecked() throws {
        let stale = try checkout(pbxproj: ["0.7.0", "0.6.9"])
        defer { stale.remove() }
        let missing = try checkout(pbxproj: ["0.7.0"])
        defer { missing.remove() }

        let staleResult = try script.run([stale.url.path])
        let missingResult = try script.run([missing.url.path])

        #expect(staleResult.status == 1)
        #expect(staleResult.errors.contains("project.pbxproj: MARKETING_VERSION is 0.6.9"))
        #expect(missingResult.status == 1)
        #expect(missingResult.errors.contains("expected MARKETING_VERSION in 2 build configurations, found 1"))
    }

    @Test func aTagForAnotherVersionFails() throws {
        let temporary = try checkout()
        defer { temporary.remove() }

        let result = try script.run([temporary.url.path], environment: ["GITHUB_REF_NAME": "v0.7.1"])

        #expect(result.status == 1)
        #expect(result.errors.contains("tag v0.7.1 doesn't match version 0.7.0"))
    }
}

/// `scripts/release-notes.sh`: a version's CHANGELOG.md section and compare link, with fenced code
/// blocks kept as they are.
@Suite("Release notes script")
struct ReleaseNotesScriptTests {
    private let script = RepositoryScript(name: "release-notes.sh")

    /// A changelog whose 0.7.0 section has code blocks holding a heading and a link reference.
    static let changelog = """
        # Changelog

        ## [Unreleased]

        ## [0.7.0] - 2026-10-20

        ### Fixed

        - Something.

        ```sh
        ## [0.6.9] inside a code block
        [0.7.0]: https://example.com/inside-code
        ```

        - After the code.

        ~~~
        ## [0.6.9] in a tilde block
        ~~~~

        ## [0.6.9] - 2026-10-01

        - Old.

        [0.7.0]: https://github.com/x/y/compare/v0.6.9...v0.7.0
        [0.6.9]: https://github.com/x/y/compare/v0.6.8...v0.6.9

        """

    private func notes(_ version: String) throws -> RepositoryScript.Result {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let file = temporary.url.appending(path: "CHANGELOG.md")
        try Data(Self.changelog.utf8).write(to: file)
        return try script.run([version], environment: ["CHANGELOG_PATH": file.path])
    }

    @Test func codeBlocksDontEndTheSection() throws {
        let result = try notes("v0.7.0")

        #expect(result.status == 0, "\(result.errors)")
        #expect(result.output == """
            ## [0.7.0] - 2026-10-20

            ### Fixed

            - Something.

            ```sh
            ## [0.6.9] inside a code block
            [0.7.0]: https://example.com/inside-code
            ```

            - After the code.

            ~~~
            ## [0.6.9] in a tilde block
            ~~~~

            **Full Changelog**: https://github.com/x/y/compare/v0.6.9...v0.7.0

            """)
    }

    @Test func aHeadingInACodeBlockIsntTheSection() throws {
        let result = try notes("0.6.9")

        #expect(result.status == 0, "\(result.errors)")
        #expect(result.output == """
            ## [0.6.9] - 2026-10-01

            - Old.

            **Full Changelog**: https://github.com/x/y/compare/v0.6.8...v0.6.9

            """)
    }

    @Test func aMissingSectionFails() throws {
        let result = try notes("0.5.0")

        #expect(result.status != 0)
        #expect(result.errors.contains("no '## [0.5.0]' section"))
    }

    @Test func theRepositoryChangelogHasTheCurrentVersion() throws {
        let result = try script.run(["v0.6.1"])
        #expect(result.status == 0, "\(result.errors)")
        #expect(result.output.hasPrefix("## [0.6.1]"))
        #expect(result.output.contains("**Full Changelog**: https://github.com/ercanatay/cybokron-dock-groups/compare/"))
    }
}
