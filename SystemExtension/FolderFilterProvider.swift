#if os(macOS)
import Darwin
import Foundation
import NetworkExtension
import os

/// Qualification only. The system only sends the selected loopback TCP port here.
final class FolderFilterProvider: NEFilterDataProvider {
    private let logger = Logger(subsystem: "io.github.d3pre5s.deusairlock.folder", category: "probe")
    private var roots: [String] = []
    private var port = ""

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        guard let options = filterConfiguration.vendorConfiguration,
              let number = options["port"] as? Int, (49152...65535).contains(number),
              let paths = options["roots"] as? [String], !paths.isEmpty,
              paths.allSatisfy({ $0.hasPrefix("/") && $0 != "/" && !$0.hasSuffix("/") })
        else {
            completionHandler(NSError(domain: "AirlockFolderProbe", code: 1))
            return
        }
        roots = paths
        port = String(number)
        let remote = NWHostEndpoint(hostname: "127.0.0.1", port: port)
        let match = NENetworkRule(remoteNetwork: remote, remotePrefix: 32, localNetwork: nil,
                                  localPrefix: 0, protocol: .TCP, direction: .outbound)
        let rule = NEFilterRule(networkRule: match, action: .filterData)
        apply(NEFilterSettings(rules: [rule], defaultAction: .allow), completionHandler: completionHandler)
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        guard let socket = flow as? NEFilterSocketFlow, flow.direction == .outbound,
              let remote = socket.remoteEndpoint as? NWHostEndpoint,
              remote.hostname == "127.0.0.1", remote.port == port else { return .allow() }

        // A missing identity must not yield a false positive in this test.
        let protected = [flow.sourceProcessAuditToken, flow.sourceAppAuditToken]
            .compactMap { $0 }.contains(where: matchesTree)
        logger.notice("Control flow matched a protected process: \(protected, privacy: .public)")
        return protected ? .drop() : .allow()
    }

    private func matchesTree(_ data: Data) -> Bool {
        guard data.count == MemoryLayout<audit_token_t>.size else { return false }
        var token = audit_token_t()
        _ = withUnsafeMutableBytes(of: &token) { data.copyBytes(to: $0) }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let capacity = UInt32(buffer.count)
        guard proc_pidpath_audittoken(&token, &buffer, capacity) > 0 else { return false }
        if matches(String(cString: buffer)) { return true }

        // A live parent chain supplies additional positive evidence only. After
        // reparenting it cannot establish the original launcher of an external tool.
        var pid = audit_token_to_pid(token)
        var chain = Set<pid_t>()
        while pid > 1 && chain.insert(pid).inserted && chain.count <= 64 {
            guard let before = process(pid) else { return false }
            let parent = pid_t(before.pbi_ppid)
            guard parent > 1, let parentBefore = process(parent),
                  proc_pidpath(parent, &buffer, capacity) > 0,
                  let parentAfter = process(parent), let after = process(pid),
                  same(parentBefore, parentAfter), same(before, after), after.pbi_ppid == before.pbi_ppid
            else { return false }
            if matches(String(cString: buffer)) {
                return proc_pidpath_audittoken(&token, &buffer, capacity) > 0
            }
            pid = parent
        }
        return false
    }

    private func process(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    private func same(_ lhs: proc_bsdinfo, _ rhs: proc_bsdinfo) -> Bool {
        lhs.pbi_pid == rhs.pbi_pid && lhs.pbi_start_tvsec == rhs.pbi_start_tvsec &&
            lhs.pbi_start_tvusec == rhs.pbi_start_tvusec
    }

    private func matches(_ path: String) -> Bool {
        roots.contains { path.hasPrefix($0 + "/") }
    }
}
#endif
