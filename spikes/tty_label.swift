// Spike M0.4: label a Terminal tab from its tty: foreground process + cwd, via libproc (no permissions).
import Foundation
import Darwin

func cwd(of pid: pid_t) -> String? {
    var info = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
    return withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
}

func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
}

func name(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 256)
    proc_name(pid, &buf, 256)
    return String(cString: buf)
}

let t0 = Date()
// All pids
let n = proc_listallpids(nil, 0)
var pids = [pid_t](repeating: 0, count: Int(n) * 2)
let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
let all = Array(pids.prefix(Int(count)))

// Group by controlling tty (e_tdev); the foreground process is the one whose pgid == tty's foreground pgid.
var byTTY: [UInt32: [(pid_t, proc_bsdinfo)]] = [:]
for pid in all {
    guard let info = bsdInfo(pid), info.e_tdev != UInt32.max, info.e_tdev != 0 else { continue }
    byTTY[info.e_tdev, default: []].append((pid, info))
}
for (dev, procs) in byTTY.sorted(by: { $0.key < $1.key }) {
    let tpgid = procs.first!.1.e_tpgid
    let fg = procs.filter { $0.1.pbi_pgid == tpgid }.max(by: { $0.0 < $1.0 })?.0 ?? procs.first!.0
    let ttyName = devname(dev_t(dev), S_IFCHR).map { String(cString: $0) } ?? "?"
    let dir = (cwd(of: fg) ?? "?").replacingOccurrences(of: NSHomeDirectory(), with: "~")
    print("/dev/\(ttyName): \(name(fg)) — \(dir)")
}
print(String(format: "scanned %d pids in %.1f ms", all.count, Date().timeIntervalSince(t0) * 1000))
