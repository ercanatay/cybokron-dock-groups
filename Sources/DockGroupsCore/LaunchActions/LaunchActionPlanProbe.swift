import Foundation

// Developer dry run for launch actions, described in `docs/design/launch-action-argv-slice.md`.
// Not a user feature: the CLI runs it only when `CYBOKRON_LAUNCH_PROBE=1` is set, and otherwise
// treats `--launch-plan` as an unknown option. Its help text, the README and the app never
// mention it.
//
// It builds the plan (`LaunchActionArgumentPlan`) for a browser, a profile name and an address and
// prints it as JSON. It starts, opens and looks up nothing: no browser is started, no address is
// opened, and whether the browser is installed isn't checked (the output says so).

/// The hidden `--launch-plan` developer dry run.
public enum LaunchActionPlanProbe {
    /// The variable that enables the dry run; only the exact value `1` does.
    public static let environmentVariable = "CYBOKRON_LAUNCH_PROBE"
    /// The CLI option, accepted only while the dry run is enabled.
    public static let option = "--launch-plan"
    /// The output format; changes when a field changes meaning.
    static let formatVersion = 1

    static let usage = """
        Usage: CYBOKRON_LAUNCH_PROBE=1 cybokrondockgroups --launch-plan <browser> <profile> <url>

        Developer dry run: prints, as JSON on stdout, the arguments a website item's browser
        profile action would start <browser> (chrome, edge, brave or firefox) with. Nothing is
        started or opened, and whether the browser is installed is not checked.
        Exit codes: 0 = planned; 2 = bad arguments; 3 = refused (the reason is in the JSON).

        """

    public static func isEnabled(environment: [String: String]) -> Bool {
        environment[environmentVariable] == "1"
    }

    /// Runs the dry run for `arguments` (the option first). Computes only.
    public static func run(arguments: [String]) -> CLIResult {
        guard arguments.count == 4, arguments[0] == option else {
            return CLIResult(exitCode: 2, output: "", errors: usage)
        }
        let report = report(browser: arguments[1], profileName: arguments[2], address: arguments[3])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(report), let json = String(data: data, encoding: .utf8) else {
            return CLIResult(exitCode: 2, output: "", errors: usage)
        }
        let summary = report.refusal.map { "Dry run: refused (\($0)); nothing was opened.\n" }
            ?? "Dry run: planned; nothing was opened.\n"
        return CLIResult(exitCode: report.refusal == nil ? 0 : 3, output: json + "\n", errors: summary)
    }

    /// The plan for the family named `browser` (its preferred bundle identifier), `profileName` and
    /// `address`, as a website item would hold them. The installation answer is always yes and
    /// reported as unchecked.
    static func report(browser: String, profileName: String, address: String) -> Report {
        guard let family = BrowserFamily(rawValue: browser) else { return Report(refusal: .unsupportedBrowser) }
        guard let url = URL(string: address) else { return Report(family: family, refusal: .urlRejected) }
        let setting = LaunchActionSetting(.browserProfile(browser: family, profileName: profileName), for: .website)
        let result = LaunchActionArgumentPlan.make(
            setting: setting,
            itemKind: .website,
            url: url,
            browserBundleIdentifier: family.bundleIdentifiers[0],
            isInstalled: { _ in true }
        )
        switch result {
        case .success(let plan): return Report(family: family, plan: plan)
        case .failure(let refusal): return Report(family: family, refusal: refusal)
        }
    }

    /// What is printed. A refused run holds only the reason and the browser family, never the
    /// profile name or address it was given.
    struct Report: Encodable, Equatable {
        let formatVersion = LaunchActionPlanProbe.formatVersion
        /// Always `true`: the dry run never starts or opens anything.
        let dryRun = true
        /// Always `false`: the dry run doesn't look for the browser.
        let installationChecked = false
        let status: String
        let browser: String?
        let executableBundleIdentifier: String?
        let arguments: [String]?
        let url: String?
        let refusal: String?

        init(family: BrowserFamily? = nil, refusal: LaunchActionArgumentRefusal) {
            status = "refused"
            browser = family?.rawValue
            executableBundleIdentifier = nil
            arguments = nil
            url = nil
            self.refusal = refusal.rawValue
        }

        init(family: BrowserFamily, plan: LaunchActionArgumentPlan) {
            status = "planned"
            browser = family.rawValue
            executableBundleIdentifier = plan.executableBundleIdentifier
            arguments = plan.arguments
            url = plan.url.absoluteString
            refusal = nil
        }

        private enum CodingKeys: String, CodingKey {
            case formatVersion, dryRun, installationChecked, status, browser, executableBundleIdentifier, arguments, url, refusal
        }
    }
}
