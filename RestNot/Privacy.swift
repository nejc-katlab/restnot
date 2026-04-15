import Foundation

struct Privacy {
    private static let redactNextFlags: Set<String> = ["-p", "--prompt", "--message", "-m"]

    static func sanitizeArgs(_ args: [String]) -> [String] {
        var result: [String] = []
        var skipNext = false

        for arg in args {
            if skipNext {
                result.append("\"…\"")
                skipNext = false
                continue
            }

            if redactNextFlags.contains(arg) {
                result.append(arg)
                skipNext = true
            } else if let eqIndex = arg.firstIndex(of: "="),
                      redactNextFlags.contains(String(arg[arg.startIndex..<eqIndex])) {
                // Handle --prompt=value format
                result.append(String(arg[arg.startIndex...eqIndex]) + "\"…\"")
            } else {
                result.append(arg)
            }
        }

        return result
    }
}
