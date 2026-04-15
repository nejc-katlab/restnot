import Foundation
import Darwin

struct WatchedProcess {
    let pid: pid_t
    let name: String
    let arguments: [String]
    let displayName: String
}

class ProcessWatcher {
    private let rules = Config.defaultWatchRules

    func scan() -> [WatchedProcess] {
        let processes = listProcesses()
        var matches: [WatchedProcess] = []
        var seenPIDs = Set<pid_t>()

        for proc in processes {
            if seenPIDs.contains(proc.pid) { continue }

            for rule in rules where rule.enabled {
                if rule.matches(name: proc.name, execBasename: proc.execBasename, args: proc.arguments) {
                    let sanitizedArgs = Privacy.sanitizeArgs(proc.arguments)
                    let name = rule.displayAs ?? proc.name
                    // Only show short, relevant args (skip paths)
                    let relevantArgs = sanitizedArgs
                        .filter { !$0.hasPrefix("/") && !$0.hasPrefix(".") }
                        .prefix(2)
                    let displayName = ([name] + relevantArgs).joined(separator: " ")

                    matches.append(WatchedProcess(
                        pid: proc.pid,
                        name: proc.name,
                        arguments: proc.arguments,
                        displayName: displayName
                    ))
                    seenPIDs.insert(proc.pid)
                    break
                }
            }
        }

        return matches
    }

    // MARK: - Process Enumeration

    private struct RawProcess {
        let pid: pid_t
        let name: String
        let executablePath: String
        let arguments: [String]

        var execBasename: String {
            (executablePath as NSString).lastPathComponent
        }
    }

    private func listProcesses() -> [RawProcess] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size: Int = 0

        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else { return [] }

        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)

        guard sysctl(&mib, UInt32(mib.count), &procs, &size, nil, 0) == 0 else { return [] }

        let actualCount = size / MemoryLayout<kinfo_proc>.stride
        var result: [RawProcess] = []

        for i in 0..<actualCount {
            let pid = procs[i].kp_proc.p_pid
            guard pid > 0 else { continue }

            let name = withUnsafePointer(to: procs[i].kp_proc.p_comm) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) { cStr in
                    String(cString: cStr)
                }
            }

            // Only fetch args for processes whose name could match a rule
            guard couldMatchAnyRule(name: name) else { continue }

            let info = getProcessArgs(pid: pid)
            result.append(RawProcess(
                pid: pid,
                name: name,
                executablePath: info.executablePath,
                arguments: info.arguments
            ))
        }

        return result
    }

    /// Quick pre-filter: does this process name appear in any rule?
    /// Avoids expensive KERN_PROCARGS2 calls for irrelevant processes.
    private func couldMatchAnyRule(name: String) -> Bool {
        return rules.contains { $0.enabled && $0.processName == name }
    }

    /// Read executable path and arguments from KERN_PROCARGS2.
    private func getProcessArgs(pid: pid_t) -> (executablePath: String, arguments: [String]) {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: Int = 0

        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else {
            return ("", [])
        }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else {
            return ("", [])
        }

        guard size > MemoryLayout<Int32>.size else {
            return ("", [])
        }

        // First 4 bytes: argc
        let argc: Int32 = buffer.withUnsafeBufferPointer { ptr in
            ptr.baseAddress!.withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }
        }

        var offset = MemoryLayout<Int32>.size

        // Read executable path (null-terminated)
        let execStart = offset
        while offset < size && buffer[offset] != 0 { offset += 1 }
        let executablePath = String(bytes: buffer[execStart..<offset], encoding: .utf8) ?? ""

        // Skip null padding
        while offset < size && buffer[offset] == 0 { offset += 1 }

        // Read argv[0..argc-1]
        var args: [String] = []
        for _ in 0..<argc {
            guard offset < size else { break }
            let argStart = offset
            while offset < size && buffer[offset] != 0 { offset += 1 }
            if let arg = String(bytes: buffer[argStart..<offset], encoding: .utf8) {
                args.append(arg)
            }
            offset += 1
        }

        // argv[0] is the executable path/name, actual args start at [1]
        let arguments = args.count > 1 ? Array(args.dropFirst()) : []
        return (executablePath, arguments)
    }
}
