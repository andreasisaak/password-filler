import Foundation
import Security
import Darwin
import os.log

/// D24: terminates `pf-nmh-bridge` processes that no longer run the bridge
/// shipped in this bundle. `BridgeStaleness` holds the verdict rule; the
/// bridge-side half (exit on a broken Agent connection) lives in
/// `NMHBridge/main.swift`.
///
/// Runs on every launch, not only on version change: a same-version dev
/// rebuild swaps the bundle exactly like a Sparkle update does, and the
/// verdict itself is what keeps healthy bridges alive — a bridge from the
/// current bundle carries the same cdhash and is left untouched.
enum StaleBridgeReaper {

    private static let log = Logger(subsystem: "app.passwordfiller.main", category: "bridge-reaper")
    private static let bridgeProcessName = "pf-nmh-bridge"

    static func reap(currentBridgePath: String) {
        guard let currentCdhash = cdhash(ofExecutableAt: currentBridgePath) else {
            log.error("cannot resolve cdhash of bundled bridge at \(currentBridgePath, privacy: .public); skipping reap")
            return
        }
        let bridges = runningBridges()
        var terminated = 0
        for bridge in bridges {
            guard case .stale(let reason) = BridgeStaleness.verdict(for: bridge, currentCdhash: currentCdhash) else {
                continue
            }
            if Darwin.kill(bridge.processID, SIGTERM) == 0 {
                terminated += 1
                log.info("terminated stale bridge pid=\(bridge.processID, privacy: .public): \(reason, privacy: .public)")
            } else {
                log.error("kill(SIGTERM) failed for stale bridge pid=\(bridge.processID, privacy: .public) errno=\(errno, privacy: .public): \(reason, privacy: .public)")
            }
        }
        log.info("bridge processes: \(bridges.count, privacy: .public) running, \(terminated, privacy: .public) stale terminated")
    }

    // MARK: - Process enumeration

    /// Every same-UID process whose kernel-side command name is
    /// `pf-nmh-bridge`. `proc_bsdinfo.pbi_comm` is derived from the executable's
    /// file name at exec time and survives deletion of that file — unlike a
    /// path lookup, which is exactly what fails for the processes we hunt.
    private static func runningBridges() -> [RunningBridgeIdentity] {
        let ownUID = getuid()
        return allProcessIDs().compactMap { pid in
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            guard info.pbi_uid == ownUID, commandName(of: info) == bridgeProcessName else { return nil }
            return identity(of: pid)
        }
    }

    private static func allProcessIDs() -> [pid_t] {
        let pidSize = Int32(MemoryLayout<pid_t>.size)
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else {
            log.error("proc_listpids sizing call failed errno=\(errno, privacy: .public)")
            return []
        }
        // Processes spawn between the two calls; the slack keeps the second
        // call from truncating the list.
        var pids = [pid_t](repeating: 0, count: Int(byteCount / pidSize) + 64)
        let filledBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count) * pidSize)
        guard filledBytes > 0 else {
            log.error("proc_listpids fill call failed errno=\(errno, privacy: .public)")
            return []
        }
        return pids.prefix(Int(filledBytes / pidSize)).filter { $0 > 0 }
    }

    private static func commandName(of info: proc_bsdinfo) -> String {
        withUnsafeBytes(of: info.pbi_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    // MARK: - Code identity

    private static func identity(of pid: pid_t) -> RunningBridgeIdentity {
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        var code: SecCode?
        let guestStatus = SecCodeCopyGuestWithAttributes(nil, attributes, [], &code)
        guard guestStatus == errSecSuccess, let code else {
            return RunningBridgeIdentity(processID: pid, cdhash: nil, lookupStatus: guestStatus)
        }
        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(code, [], &staticCode)
        guard staticStatus == errSecSuccess, let staticCode else {
            return RunningBridgeIdentity(processID: pid, cdhash: nil, lookupStatus: staticStatus)
        }
        let resolved = cdhash(of: staticCode)
        return RunningBridgeIdentity(processID: pid, cdhash: resolved.cdhash, lookupStatus: resolved.status)
    }

    private static func cdhash(ofExecutableAt path: String) -> Data? {
        var staticCode: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode)
        guard status == errSecSuccess, let staticCode else {
            log.error("SecStaticCodeCreateWithPath failed for \(path, privacy: .public): OSStatus \(status, privacy: .public)")
            return nil
        }
        return cdhash(of: staticCode).cdhash
    }

    private static func cdhash(of staticCode: SecStaticCode) -> (cdhash: Data?, status: OSStatus) {
        var information: CFDictionary?
        let status = SecCodeCopySigningInformation(staticCode, [], &information)
        guard status == errSecSuccess else { return (nil, status) }
        guard let dictionary = information as? [String: Any],
              let cdhash = dictionary[kSecCodeInfoUnique as String] as? Data else {
            return (nil, errSecCSInternalError)
        }
        return (cdhash, errSecSuccess)
    }
}
