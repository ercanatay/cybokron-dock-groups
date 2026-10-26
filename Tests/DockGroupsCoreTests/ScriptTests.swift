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

    /// A checkout with only the three files the script reads. The build numbers default to the
    /// one 0.7.0 needs (700).
    private func checkout(
        buildScript: String = "0.7.0",
        projectYML: String = "0.7.0",
        pbxproj: [String] = ["0.7.0", "0.7.0"],
        buildNumber: String = "700",
        projectYMLBuild: String = "700",
        pbxprojBuilds: [String] = ["700", "700"]
    ) throws -> TemporaryDirectory {
        let temporary = try TemporaryDirectory()
        let configurations = zip(pbxproj, pbxprojBuilds).map { version, build in
            "\t\t\t\tCURRENT_PROJECT_VERSION = \(build);\n\t\t\t\tMARKETING_VERSION = \(version);\n\t\t\t\tPRODUCT_NAME = x;\n"
        }
        let files: [(String, String)] = [
            ("scripts/build-app.sh", "#!/usr/bin/env bash\nAPP_NAME=\"Cybokron Dock Groups\"\nMARKETING_VERSION=\"\(buildScript)\"\nBUILD_NUMBER=\"\(buildNumber)\"\n"),
            ("project.yml", "settings:\n  base:\n    MARKETING_VERSION: \"\(projectYML)\"\n    CURRENT_PROJECT_VERSION: \"\(projectYMLBuild)\"\n"),
            ("CybokronDockGroups.xcodeproj/project.pbxproj", configurations.joined()),
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

    @Test func theBuildNumberIsDerivedFromTheVersion() throws {
        let stale = try checkout(buildNumber: "1", projectYMLBuild: "1", pbxprojBuilds: ["1", "1"])
        defer { stale.remove() }
        let oneConfiguration = try checkout(pbxprojBuilds: ["700", "699"])
        defer { oneConfiguration.remove() }
        let later = try checkout(buildScript: "1.2.3", projectYML: "1.2.3", pbxproj: ["1.2.3", "1.2.3"], buildNumber: "10203", projectYMLBuild: "10203", pbxprojBuilds: ["10203", "10203"])
        defer { later.remove() }
        let tooBig = try checkout(buildScript: "0.100.0", projectYML: "0.100.0", pbxproj: ["0.100.0", "0.100.0"])
        defer { tooBig.remove() }

        let staleResult = try script.run([stale.url.path])
        let oneResult = try script.run([oneConfiguration.url.path])
        let laterResult = try script.run([later.url.path])
        let tooBigResult = try script.run([tooBig.url.path])

        #expect(staleResult.status == 1)
        #expect(staleResult.errors.contains("scripts/build-app.sh: BUILD_NUMBER is 1, version 0.7.0 needs 700"))
        #expect(staleResult.errors.contains("project.yml: CURRENT_PROJECT_VERSION is 1, version 0.7.0 needs 700"))
        #expect(staleResult.errors.contains("project.pbxproj: CURRENT_PROJECT_VERSION is 1"))
        #expect(oneResult.status == 1)
        #expect(oneResult.errors.contains("project.pbxproj: CURRENT_PROJECT_VERSION is 699, version 0.7.0 needs 700"))
        #expect(laterResult.status == 0, "\(laterResult.errors)")
        #expect(laterResult.output.contains("Version 1.2.3 (build 10203)"))
        #expect(tooBigResult.status == 1)
        #expect(tooBigResult.errors.contains("minor and patch must be below 100"))
    }

    @Test func theRepositorysBuildNumberFollowsItsVersion() throws {
        let result = try script.run()
        #expect(result.status == 0, "\(result.errors)")
        #expect(result.output.contains("(build "))
        #expect(!result.output.contains("(build 1)"))
    }

    @Test func aBuiltAppMustCarryTheVersionAndBuildNumber() throws {
        let temporary = try checkout()
        defer { temporary.remove() }
        func app(version: String, build: String) throws -> URL {
            let bundle = temporary.url.appending(path: "App-\(version)-\(build).app", directoryHint: .isDirectory)
            let contents = bundle.appending(path: "Contents", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": version, "CFBundleVersion": build], format: .xml, options: 0)
                .write(to: contents.appending(path: "Info.plist"))
            return bundle
        }

        let good = try script.run([temporary.url.path], environment: ["APP_PATH": try app(version: "0.7.0", build: "700").path])
        let oldBuild = try script.run([temporary.url.path], environment: ["APP_PATH": try app(version: "0.7.0", build: "1").path])

        #expect(good.status == 0, "\(good.errors)")
        #expect(good.output.contains("CFBundleVersion: 700"))
        #expect(oldBuild.status == 1)
        #expect(oldBuild.errors.contains("CFBundleVersion is 1, expected 700"))
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

/// `.github/workflows/*.yml`: third-party code runs only at a reviewed commit, checkouts don't keep
/// the token, and the release job's signing steps stay locked down.
@Suite("CI workflows")
struct WorkflowTests {
    static let workflows = RepositoryScript.root.appending(components: ".github", "workflows", directoryHint: .isDirectory)

    static func files() throws -> [(name: String, text: String)] {
        let names = try FileManager.default.contentsOfDirectory(atPath: workflows.path)
            .filter { $0.hasSuffix(".yml") || $0.hasSuffix(".yaml") }
            .sorted()
        return try names.map { ($0, try String(contentsOf: workflows.appending(path: $0), encoding: .utf8)) }
    }

    static func lines(_ text: String, containing needle: String) -> [String] {
        text.components(separatedBy: .newlines).filter { $0.contains(needle) && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
    }

    @Test func everyActionIsPinnedToACommitWithItsVersionInAComment() throws {
        let pinned = try NSRegularExpression(pattern: #"uses:\s*[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}\s+#\s*v\d+(\.\d+)*\s*$"#)
        let files = try Self.files()
        #expect(!files.isEmpty)
        var count = 0
        for (name, text) in files {
            for line in Self.lines(text, containing: "uses:") {
                count += 1
                #expect(pinned.numberOfMatches(in: line, range: NSRange(line.startIndex..., in: line)) == 1, "\(name): not pinned to a commit SHA: \(line)")
            }
        }
        #expect(count >= 5)
    }

    @Test func checkoutsDontPersistTheToken() throws {
        for (name, text) in try Self.files() {
            let checkouts = Self.lines(text, containing: "actions/checkout@").count
            let persisted = Self.lines(text, containing: "persist-credentials: false").count
            #expect(checkouts == persisted, "\(name): \(checkouts) checkouts, \(persisted) with persist-credentials: false")
        }
    }

    @Test func theReleaseJobIsLockedDown() throws {
        let text = try String(contentsOf: Self.workflows.appending(path: "swift.yml"), encoding: .utf8)

        #expect(Self.lines(text, containing: "environment: release").count == 1)
        // Only codesign may use the imported private key.
        #expect(Self.lines(text, containing: "-T /usr/bin/security").isEmpty)
        #expect(Self.lines(text, containing: "-T /usr/bin/codesign").count == 1)
        // A .p12 with more than the Developer ID identity stops the job.
        #expect(text.contains(#"[[ "$COUNT" == 1 ]] \"#))
        #expect(text.contains(#"it must hold only the Developer ID Application one"; exit 1; }"#))
    }

    @Test(arguments: ["swiftpm", "release"])
    func distributedAppsRequireNonemptyAppIntentsMetadata(job: String) throws {
        let workflow = try String(contentsOf: Self.workflows.appending(path: "swift.yml"), encoding: .utf8)
        let remainder = try #require(workflow.components(separatedBy: "\n  \(job):").dropFirst().first)
        let jobText = remainder.components(separatedBy: .newlines).prefix { line in
            !(line.hasPrefix("  ") && !line.hasPrefix("   ") && line.hasSuffix(":"))
        }.joined(separator: "\n")
        let steps = jobText.components(separatedBy: "      - name: ")
        let gate = try #require(steps.first { $0.hasPrefix("Verify App Intents metadata\n") })
        let body = try #require(gate.components(separatedBy: "        run: |\n").dropFirst().first)
        let script = body.components(separatedBy: .newlines).map { String($0.dropFirst(10)) }.joined(separator: "\n")
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let metadata = temporary.url.appending(path: "build/release/Cybokron Dock Groups.app/Contents/Resources/Metadata.appintents/extract.actionsdata")
        try FileManager.default.createDirectory(at: metadata.deletingLastPathComponent(), withIntermediateDirectories: true)
        for state in ["missing", "empty", "present"] {
            if state != "missing" { try Data((state == "present" ? "actions" : "").utf8).write(to: metadata) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-e", "-c", script]
            process.currentDirectoryURL = temporary.url
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect((process.terminationStatus == 0) == (state == "present"), "\(job): \(state) metadata")
        }
    }
}

/// Executes the real packaging script in a tiny checkout, with an Xcode 26-style compiler that
/// supports const gathering through the frontend but rejects the newer driver-only spelling.
@Suite("SwiftPM App Intents packaging")
struct AppIntentsPackagingTests {
    private struct Toolchain {
        let temporary: TemporaryDirectory
        let root: URL

        init() throws {
            temporary = try TemporaryDirectory()
            root = temporary.url.appending(path: "checkout with spaces")
            for name in ["build-app.sh", "swiftpm-env.sh", "appintents-const-protocols.json"] {
                try write("scripts/\(name)", String(contentsOf: RepositoryScript.root.appending(components: "scripts", name), encoding: .utf8))
            }
            try write("Resources/Info.plist", "<plist version=\"1.0\"><dict/></plist>")
            try write("Resources/en.lproj/Localizable.strings", "\"test\" = \"test\";")
            try write("Resources/Assets.xcassets/AppIcon.appiconset/icon_16.png", "fixture")
            try write("Sources/CybokronDockGroups/AppDelegate.swift", "// fixture")
            for tool in ["xcrun", "swiftc", "swift", "appintentsmetadataprocessor", "xcode-select", "xcodebuild", "plutil", "iconutil", "codesign", "lipo"] {
                try write("bin/\(tool)", Self.stub, executable: true)
            }
        }

        func write(_ path: String, _ text: String, executable: Bool = false) throws {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            if executable {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
        }

        func run(_ configuration: String = "release", mode: String = "supported", metadata: String = "present") throws -> RepositoryScript.Result {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [root.appending(path: "scripts/build-app.sh").path, configuration]
            var environment = ProcessInfo.processInfo.environment
            for key in ["CODESIGN_IDENTITY", "DEVELOPER_DIR", "SDKROOT"] { environment.removeValue(forKey: key) }
            environment.merge([
                "PATH": root.appending(path: "bin").path + ":/usr/bin:/bin",
                "FIXTURE_ROOT": root.path, "FIXTURE_MODE": mode, "FIXTURE_METADATA": metadata,
                "SWIFTPM_SCRATCH_PATH": root.appending(path: "scratch").path, "UNIVERSAL": "1",
            ]) { $1 }
            if mode == "clt" { environment["SDKROOT"] = "/SDK/MacOSX26.sdk" }
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            // Files keep a failed stub's diagnostics from filling a pipe and blocking the test.
            let output = root.appending(path: "stdout")
            let errors = root.appending(path: "stderr")
            try Data().write(to: output)
            try Data().write(to: errors)
            let outputHandle = try FileHandle(forWritingTo: output)
            let errorHandle = try FileHandle(forWritingTo: errors)
            defer { try? outputHandle.close(); try? errorHandle.close() }
            process.standardOutput = outputHandle
            process.standardError = errorHandle
            try process.run()
            process.waitUntilExit()
            return RepositoryScript.Result(status: process.terminationStatus,
                output: try String(contentsOf: output, encoding: .utf8),
                errors: try String(contentsOf: errors, encoding: .utf8))
        }

        func text(_ path: String) throws -> String {
            try String(contentsOf: root.appending(path: path), encoding: .utf8)
        }

        private static let stub = #"""
            #!/bin/bash
            set -euo pipefail
            tool="${0##*/}"
            printf '%s\n' "$tool" >> "$FIXTURE_ROOT/calls"
            case "$tool" in
                xcode-select)
                    if [[ "$FIXTURE_MODE" == clt ]]; then
                        echo /Library/Developer/CommandLineTools
                    else
                        echo /Applications/Xcode.app/Contents/Developer
                    fi ;;
                xcrun)
                    if [[ "$1" == --find ]]; then
                        [[ "$FIXTURE_MODE" != clt ]] || exit 1
                        echo "$FIXTURE_ROOT/bin/appintentsmetadataprocessor"
                    elif [[ "$1" == swiftc ]]; then
                        shift
                        exec "$FIXTURE_ROOT/bin/swiftc" "$@"
                    else
                        echo /SDK/MacOSX.sdk
                    fi ;;
                swiftc)
                    printf '%s\n' "$@" > "$FIXTURE_ROOT/probe-arguments"
                    [[ "$FIXTURE_MODE" != unsupported ]] || exit 1
                    arguments=("$@")
                    count=${#arguments[@]}
                    # Reject the driver-only flag on the simulated Xcode 26 toolchain.
                    for argument in "$@"; do
                        [[ "$argument" != -const-gather-protocols-list ]] || exit 1
                    done
                    [[ "${arguments[$((count-5))]}" == -emit-const-values ]]
                    [[ "${arguments[$((count-4))]}" == -Xfrontend ]]
                    [[ "${arguments[$((count-3))]}" == -const-gather-protocols-file ]]
                    [[ "${arguments[$((count-2))]}" == -Xfrontend ]]
                    [[ "${arguments[$((count-1))]}" == "$FIXTURE_ROOT/scripts/appintents-const-protocols.json" ]]
                    grep -q '"AppIntent"' "${arguments[$((count-1))]}" ;;
                swift)
                    printf '%s\n' "$@" >> "$FIXTURE_ROOT/build-arguments"
                    configuration=debug
                    previous=""
                    for argument in "$@"; do
                        [[ "$previous" != -c ]] || configuration="$argument"
                        previous="$argument"
                    done
                    if [[ "$FIXTURE_MODE" != clt ]]; then
                        expected=(-Xswiftc -emit-const-values -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file -Xswiftc -Xfrontend -Xswiftc "$FIXTURE_ROOT/scripts/appintents-const-protocols.json")
                        arguments=("$@")
                        found=0
                        for ((i=0; i+${#expected[@]}<=${#arguments[@]}; i++)); do
                            match=1
                            for ((j=0; j<${#expected[@]}; j++)); do
                                [[ "${arguments[$((i+j))]}" == "${expected[$j]}" ]] || match=0
                            done
                            [[ "$match" != 1 ]] || found=1
                        done
                        [[ "$found" == 1 ]] || { echo 'missing SwiftPM frontend forwarding' >&2; exit 1; }
                    fi
                    directory="$SWIFTPM_SCRATCH_PATH/arm64-apple-macosx/$configuration"
                    mkdir -p "$directory/CybokronDockGroups.build"
                    printf 'binary' > "$directory/CybokronDockGroups"
                    printf 'constant values' > "$directory/CybokronDockGroups.build/AppDelegate.swiftconstvalues"
                    [[ " $* " != *' --show-bin-path '* ]] || echo "$directory" ;;
                appintentsmetadataprocessor)
                    output=""
                    while [[ $# -gt 0 ]]; do
                        case "$1" in
                            --output) output="$2"; shift ;;
                            --swift-const-vals-list)
                                [[ -s "$2" ]]
                                while IFS= read -r values; do [[ -s "$values" ]]; done < "$2"
                                shift ;;
                        esac
                        shift
                    done
                    mkdir -p "$output/Metadata.appintents"
                    case "$FIXTURE_METADATA" in
                        present) printf 'actions' > "$output/Metadata.appintents/extract.actionsdata" ;;
                        empty) touch "$output/Metadata.appintents/extract.actionsdata" ;;
                        missing) ;;
                    esac ;;
                xcodebuild) echo 'Build version fixture' ;;
                iconutil) touch "$4" ;;
                lipo) echo 'arm64 x86_64' ;;
                plutil | codesign) ;;
            esac
            """#
    }

    @Test(arguments: ["debug", "release"])
    func xcode26FrontendFlagsProducePackagedMetadata(configuration: String) throws {
        let fixture = try Toolchain()
        defer { fixture.temporary.remove() }
        let result = try fixture.run(configuration)

        #expect(result.status == 0, "\(result.output)\n\(result.errors)")
        #expect(try fixture.text("build/\(configuration)/Cybokron Dock Groups.app/Contents/Resources/Metadata.appintents/extract.actionsdata") == "actions")
        let arguments = try fixture.text("build-arguments")
        #expect(arguments.contains("--arch\narm64\n--arch\nx86_64\n"))
        #expect(result.output.contains("App Intents metadata:"))
        #expect(try fixture.text("calls").contains("codesign\ncodesign\n"))
    }

    @Test func anAvailableProcessorWithAnUnsupportedCompilerFailsBeforeBuilding() throws {
        let fixture = try Toolchain()
        defer { fixture.temporary.remove() }
        let result = try fixture.run(mode: "unsupported")

        #expect(result.status != 0)
        #expect(result.errors.contains("compiler does not support App Intents constant gathering"))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "build-arguments").path))
    }

    @Test(arguments: ["missing", "empty"])
    func extractionMustProduceNonemptyMetadata(metadata: String) throws {
        let fixture = try Toolchain()
        defer { fixture.temporary.remove() }
        let result = try fixture.run(metadata: metadata)

        #expect(result.status != 0)
        #expect(result.errors.contains("App Intents metadata extraction produced no nonempty"))
        #expect(try !fixture.text("calls").contains("codesign"))
    }

    @Test func commandLineToolsMayBuildWithoutShortcutsActions() throws {
        let fixture = try Toolchain()
        defer { fixture.temporary.remove() }
        let result = try fixture.run(mode: "clt")

        #expect(result.status == 0, "\(result.errors)")
        #expect(result.errors.contains("Siri and Shortcuts won't list this build's actions"))
        let calls = try fixture.text("calls")
        #expect(!calls.contains("swiftc"))
        #expect(!calls.contains("appintentsmetadataprocessor"))
        #expect(calls.contains("codesign"))
    }
}
