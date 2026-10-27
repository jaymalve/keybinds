import Darwin
import Foundation

/// Labels a terminal tab by its foreground process and that process's working directory, via libproc
/// (spike M0.4a: no permissions needed).
enum TerminalLabels {
    struct Label: Sendable {
        let process: String
        let cwd: String?
    }

    /// Resolves only the given ttys (e.g. "/dev/ttys004"). One pass over all pids (~50 ms), background only.
    static func labels(for ttys: Set<String>) -> [String: Label] {
        guard !ttys.isEmpty else { return [:] }
        let devices = Dictionary(uniqueKeysWithValues: ttys.compactMap { tty -> (UInt32, String)? in
            var st = stat()
            return stat(tty, &st) == 0 ? (UInt32(bitPattern: st.st_rdev), tty) : nil
        })

        let capacity = proc_listallpids(nil, 0) * 2
        var pids = [pid_t](repeating: 0, count: Int(capacity))
        let count = Int(proc_listallpids(&pids, capacity * Int32(MemoryLayout<pid_t>.size)))

        // Per tty, the foreground process group's newest process.
        var foreground: [String: pid_t] = [:]
        for pid in pids.prefix(count) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  let tty = devices[info.e_tdev], info.pbi_pgid == info.e_tpgid else { continue }
            if pid > (foreground[tty] ?? 0) { foreground[tty] = pid }
        }

        return foreground.mapValues { pid in Label(process: name(pid), cwd: cwd(pid)) }
    }

    private static func name(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buf, 256)
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func cwd(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
