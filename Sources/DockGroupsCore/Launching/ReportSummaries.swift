import Foundation

// One-sentence results of Open All and Close All, for Siri and the Shortcuts app. Items are named
// as lists show them (`displayName`: an alias, when they have one).

extension LaunchReport {
    public var summary: String {
        let total = entries.count
        guard total > 0 else { return "“\(groupName)” has no apps yet." }
        let problems = self.problems
        let opened = total - problems.count
        let problemNames = problems.map(\.app.displayName).joined(separator: ", ")
        if problems.isEmpty {
            return total == 1 ? "Opened the app in “\(groupName)”." : "Opened all \(total) apps in “\(groupName)”."
        }
        if opened == 0 {
            return "Couldn't open the apps in “\(groupName)”: \(problemNames)."
        }
        return "Opened \(opened) of \(total) apps in “\(groupName)”. Couldn't open \(problemNames)."
    }
}

extension QuitReport {
    public var summary: String {
        if quit.isEmpty, refused.isEmpty, kept.isEmpty {
            return "None of the apps in “\(groupName)” are running."
        }
        var sentences: [String] = []
        if !quit.isEmpty {
            let apps = Self.appCount(quit.count)
            sentences.append(mode == .force
                ? "Force quit \(apps) in “\(groupName)”."
                : "Asked \(apps) in “\(groupName)” to quit.")
        }
        if !refused.isEmpty {
            sentences.append("Couldn't quit \(refused.map(\.displayName).joined(separator: ", ")).")
        }
        if !kept.isEmpty {
            let names = kept.map(\.displayName)
            sentences.append(names.count == 1
                ? "\(names[0]) is protected and stays open."
                : "\(TransitionReport.joined(names)) are protected and stay open.")
        }
        return sentences.joined(separator: " ")
    }

    private static func appCount(_ count: Int) -> String {
        count == 1 ? "1 app" : "\(count) apps"
    }
}
