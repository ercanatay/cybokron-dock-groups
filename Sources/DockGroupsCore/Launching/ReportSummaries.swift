import Foundation

// One-sentence results of Open All and Close All, for Siri and the Shortcuts app.

extension LaunchReport {
    public var summary: String {
        let total = entries.count
        guard total > 0 else { return "“\(groupName)” has no apps yet." }
        let problems = self.problems
        let opened = total - problems.count
        let problemNames = problems.map(\.app.name).joined(separator: ", ")
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
        if quit.isEmpty, refused.isEmpty {
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
            sentences.append("Couldn't quit \(refused.map(\.name).joined(separator: ", ")).")
        }
        return sentences.joined(separator: " ")
    }

    private static func appCount(_ count: Int) -> String {
        count == 1 ? "1 app" : "\(count) apps"
    }
}
