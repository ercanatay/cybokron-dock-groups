import Foundation

/// What starting or finishing a group did (`ContextSwitcher`).
public struct TransitionReport: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// The plan was carried out.
        case done
        /// The group was started again right after it was started (`ContextSession.repeatInterval`):
        /// nothing was done.
        case repeated
        /// The user answered a link's question with Cancel: nothing was done.
        case declined
        /// Another link's question was showing, so this link's was dropped: nothing was done.
        case dropped
    }

    public let outcome: Outcome
    /// The plan as carried out — with quitting turned into hiding when the user chose "Hide
    /// Instead" — or as it would have been.
    public let plan: TransitionPlan
    /// Start: what opening the group's items did.
    public var launch: LaunchReport?
    public var hidden = RunningAppsReport()
    public var quit = RunningAppsReport()
    public var shown = RunningAppsReport()

    /// Apps the settings would have hidden or quit but that were left alone, and why.
    public var kept: [TransitionPlan.Entry] { plan.kept }

    /// Whether anything went wrong: an item that didn't open, an app that didn't hide or quit.
    public var hasProblems: Bool {
        !(launch?.problems.isEmpty ?? true) || !hidden.refused.isEmpty || !quit.refused.isEmpty
    }
}

// The one-sentence result for Siri and the Shortcuts app, in English as the other summaries
// (`ReportSummaries.swift`). Items and apps are named as lists show them.

extension TransitionReport {
    public var summary: String {
        let group = plan.groupName
        let isStart: Bool
        if case .start = plan.kind { isStart = true } else { isStart = false }
        switch outcome {
        case .repeated:
            return "“\(group)” was just started."
        case .declined, .dropped:
            return isStart ? "Didn't switch to “\(group)”." : "Didn't finish “\(group)”."
        case .done:
            break
        }

        let other = plan.otherGroupName.map { " of “\($0)”" } ?? ""
        var clauses: [String] = []
        if let launch {
            let opened = launch.entries.count - launch.problems.count - launch.scheduled.count
            if opened > 0 { clauses.append("opened \(Self.count(opened, "item"))") }
        }
        if !hidden.done.isEmpty {
            let apps = Self.count(hidden.done.count, "app")
            if !isStart {
                clauses.append("hid \(apps)")
            } else if plan.hide.contains(where: { $0.reason == .notInStartedGroup }) {
                clauses.append("hid \(Self.count(hidden.done.count, "other app"))")
            } else {
                clauses.append("hid \(apps)\(other)")
            }
        }
        if !quit.done.isEmpty {
            clauses.append("asked \(Self.count(quit.done.count, "app"))\(isStart ? other : "") to quit")
        }
        if !isStart, let next = plan.otherGroupName {
            clauses.append("showed “\(next)” again")
        }
        var sentences = [clauses.isEmpty
            ? (isStart ? "Started “\(group)”." : "Finished “\(group)”.")
            : "\(isStart ? "Started" : "Finished") “\(group)”: \(Self.joined(clauses))."]

        if let later = launch?.scheduled.count, later > 0 {
            sentences.append(later == 1 ? "1 more item opens in a few seconds." : "\(later) more items open in a few seconds.")
        }
        if let problems = launch?.problems, !problems.isEmpty {
            sentences.append("Couldn't open \(problems.map(\.app.displayName).joined(separator: ", ")).")
        }
        if !hidden.refused.isEmpty {
            sentences.append("Couldn't hide \(hidden.refused.map(\.name).joined(separator: ", ")).")
        }
        if !quit.refused.isEmpty {
            sentences.append("Couldn't quit \(quit.refused.map(\.name).joined(separator: ", ")).")
        }
        let protected = kept.filter { $0.reason == .protected }.map(\.app.name)
        if !protected.isEmpty {
            sentences.append(protected.count == 1
                ? "\(protected[0]) is protected and stays open."
                : "\(Self.joined(protected)) are protected and stay open.")
        }
        return sentences.joined(separator: " ")
    }

    static func count(_ count: Int, _ noun: String) -> String {
        count == 1 ? "1 \(noun)" : "\(count) \(noun)s"
    }

    /// "a", "a and b", "a, b and c".
    static func joined(_ parts: [String]) -> String {
        guard parts.count > 1 else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
    }
}
