import Foundation

enum MatchMode {
    case nameOnly
    case nameAndArgs
}

struct WatchRule {
    let processName: String
    let argPatterns: [String]
    let matchMode: MatchMode
    let displayAs: String?
    let enabled: Bool

    func matches(name: String, execBasename: String, args: [String]) -> Bool {
        guard enabled else { return false }

        let nameMatch = name == processName || execBasename == processName
        guard nameMatch else { return false }

        switch matchMode {
        case .nameOnly:
            return true
        case .nameAndArgs:
            guard !argPatterns.isEmpty else { return false }
            let joinedArgs = args.joined(separator: " ")
            return argPatterns.contains { joinedArgs.contains($0) }
        }
    }
}

struct Config {
    static let pollInterval: TimeInterval = 5.0
    static let gracePeriod: TimeInterval = 30.0

    static let defaultWatchRules: [WatchRule] = [
        // Claude Code — any running instance
        WatchRule(processName: "claude", argPatterns: [], matchMode: .nameOnly, displayAs: nil, enabled: true),
        // Claude Code via npm (node process running claude)
        WatchRule(processName: "node", argPatterns: ["claude"], matchMode: .nameAndArgs, displayAs: "claude", enabled: true),
        // SSH & file transfers
        WatchRule(processName: "ssh", argPatterns: [], matchMode: .nameOnly, displayAs: nil, enabled: true),
        WatchRule(processName: "rsync", argPatterns: [], matchMode: .nameOnly, displayAs: nil, enabled: true),
        WatchRule(processName: "scp", argPatterns: [], matchMode: .nameOnly, displayAs: nil, enabled: true),
        // Build tools
        WatchRule(processName: "cargo", argPatterns: ["build", "test", "run"], matchMode: .nameAndArgs, displayAs: nil, enabled: true),
        WatchRule(processName: "xcodebuild", argPatterns: [], matchMode: .nameOnly, displayAs: nil, enabled: true),
        WatchRule(processName: "make", argPatterns: [], matchMode: .nameOnly, displayAs: nil, enabled: true),
        // Docker
        WatchRule(processName: "docker", argPatterns: ["run", "compose", "build"], matchMode: .nameAndArgs, displayAs: nil, enabled: true),
    ]
}
