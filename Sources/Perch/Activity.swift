import AppKit
import Darwin
import SwiftUI

struct AppLoad: Identifiable, Hashable {
    let id: String          // bundle path or process name
    let name: String
    let bundlePath: String?
    var cpu: Double         // % of one core, like Activity Monitor
    var memory: Int64       // physical footprint
    var pids: [pid_t]
}

struct SystemLoad {
    var cpu: Double = 0             // 0–100, all cores
    var memUsed: Int64 = 0
    var memTotal: Int64 = Int64(ProcessInfo.processInfo.physicalMemory)
    var pressure = 1                // 1 normal, 2 warning, 4 critical
}

/// Samples per-process CPU time and memory with libproc. Only processes owned by the
/// user are readable without root, which covers every app you launch yourself.
final class ProcessSampler: @unchecked Sendable {
    private var lastCPU: [pid_t: UInt64] = [:]     // ns
    private var groupCache: [pid_t: (key: String, name: String, bundle: String?)] = [:]
    private var lastSample: UInt64 = 0
    private var lastHostTicks: (busy: UInt64, total: UInt64)?
    private let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    func sample() -> ([AppLoad], SystemLoad) {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = lastSample == 0 ? 0 : Double(now - lastSample)
        lastSample = now

        let count = proc_listallpids(nil, 0)
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var groups: [String: AppLoad] = [:]
        var seen = Set<pid_t>()

        for pid in pids.prefix(max(0, n)) where pid > 0 {
            var info = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard ok == 0 else { continue }
            seen.insert(pid)
            let cpuNs = (info.ri_user_time + info.ri_system_time) * timebase.numer / timebase.denom
            var cpu = 0.0
            if elapsed > 0, let prev = lastCPU[pid], cpuNs >= prev {
                cpu = Double(cpuNs - prev) / elapsed * 100
            }
            lastCPU[pid] = cpuNs

            let g = groupCache[pid] ?? group(for: pid)
            groupCache[pid] = g
            var entry = groups[g.key] ?? AppLoad(id: g.key, name: g.name, bundlePath: g.bundle, cpu: 0, memory: 0, pids: [])
            entry.cpu += cpu
            entry.memory += Int64(info.ri_phys_footprint)
            entry.pids.append(pid)
            groups[g.key] = entry
        }
        // Forget exited processes so pid reuse can't mix up apps.
        lastCPU = lastCPU.filter { seen.contains($0.key) }
        groupCache = groupCache.filter { seen.contains($0.key) }
        return (Array(groups.values), systemLoad())
    }

    private func group(for pid: pid_t) -> (key: String, name: String, bundle: String?) {
        var buf = [CChar](repeating: 0, count: 4096)
        let len = proc_pidpath(pid, &buf, UInt32(buf.count))
        let path = len > 0 ? String(cString: buf) : ""
        // First ".app/" = outermost bundle, so helpers (Chrome Helper, XPC services) roll up into their app.
        if let r = path.range(of: ".app/") {
            let bundle = String(path[..<r.lowerBound]) + ".app"
            let name = (FileManager.default.displayName(atPath: bundle) as NSString).deletingPathExtension
            return (bundle, name, bundle)
        }
        var nameBuf = [CChar](repeating: 0, count: 256)
        proc_name(pid, &nameBuf, UInt32(nameBuf.count))
        var name = String(cString: nameBuf)
        if name.isEmpty { name = (path as NSString).lastPathComponent }
        if name.isEmpty { name = "pid \(pid)" }
        return ("proc:" + name, name, nil)
    }

    private func systemLoad() -> SystemLoad {
        var load = SystemLoad()

        var cpuInfo = host_cpu_load_info()
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &cpuInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        if r == KERN_SUCCESS {
            let t = cpuInfo.cpu_ticks
            let user = UInt64(t.0), sys = UInt64(t.1), idle = UInt64(t.2), nice = UInt64(t.3)
            let busy = user + sys + nice, total = busy + idle
            if let last = lastHostTicks, total > last.total {
                load.cpu = Double(busy - last.busy) / Double(total - last.total) * 100
            }
            lastHostTicks = (busy, total)
        }

        var vm = vm_statistics64()
        var vmSize = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let vr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmSize)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vmSize)
            }
        }
        if vr == KERN_SUCCESS {
            let page = Int64(vm_kernel_page_size)
            // Same definition as Activity Monitor's "Memory Used": app + wired + compressed.
            let app = Int64(vm.internal_page_count) - Int64(vm.purgeable_count)
            load.memUsed = (app + Int64(vm.wire_count) + Int64(vm.compressor_page_count)) * page
        }

        var level: Int32 = 1
        var len = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &len, nil, 0) == 0 { load.pressure = Int(level) }
        return load
    }
}

@MainActor
final class ActivityModel: ObservableObject {
    struct Row: Identifiable, Hashable {
        let id: String
        let name: String
        let bundlePath: String?
        let detail: String?
        let share: Double       // 0…1 of the whole Mac (all cores / all RAM)
        let value: String
        let quittable: Bool
        let pids: [pid_t]
    }

    @Published var showBackground = false { didSet { rebuild() } }
    @Published private(set) var cpuRows: [Row] = []
    @Published private(set) var memRows: [Row] = []
    @Published private(set) var system = SystemLoad()
    @Published private(set) var ready = false
    private var apps: [AppLoad] = []
    private let sampler = ProcessSampler()
    private let queue = DispatchQueue(label: "perch.activity", qos: .utility)
    private var timer: Timer?
    private let cores = Double(ProcessInfo.processInfo.activeProcessorCount)

    /// Sampling runs only while the tab is on screen.
    func start() {
        guard timer == nil else { return }
        tick()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let sampler = sampler
        queue.async {
            let (apps, system) = sampler.sample()
            DispatchQueue.main.async {
                self.apps = apps
                self.system = system
                self.rebuild()
                self.ready = true
            }
        }
    }

    /// Apps with a Dock presence = things the user opened. Everything else is "system & background".
    private func rebuild() {
        let visible = Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { $0.bundleURL?.path })
        var shown: [AppLoad] = []
        var rest = AppLoad(id: "background", name: L("Sistem ve arka plan"), bundlePath: nil, cpu: 0, memory: 0, pids: [])
        var restCount = 0
        for a in apps {
            if showBackground || (a.bundlePath.map(visible.contains) ?? false) {
                shown.append(a)
            } else {
                rest.cpu += a.cpu
                rest.memory += a.memory
                restCount += 1
            }
        }
        func row(_ a: AppLoad, cpu: Bool) -> Row {
            let isRest = a.id == "background"
            let detail = isRest ? L("%d işlem", restCount) : (a.pids.count > 1 ? L("%d işlem", a.pids.count) : nil)
            let share = cpu ? a.cpu / 100 / cores : Double(a.memory) / Double(max(system.memTotal, 1))
            let value = cpu ? Self.percent(share) : Fmt.bytes(a.memory)
            return Row(id: a.id, name: a.name, bundlePath: a.bundlePath, detail: detail, share: share,
                       value: value, quittable: !isRest, pids: a.pids)
        }
        let limit = 7
        cpuRows = (shown.sorted { $0.cpu > $1.cpu }.prefix(limit) + (showBackground ? [] : [rest]))
            .map { row($0, cpu: true) }
        memRows = (shown.sorted { $0.memory > $1.memory }.prefix(limit) + (showBackground ? [] : [rest]))
            .map { row($0, cpu: false) }
    }

    static func percent(_ share: Double) -> String {
        let p = share * 100
        return p < 1 ? (p < 0.1 ? "%0" : String(format: "%%%.1f", p)) : "%\(Int(p.rounded()))"
    }

    var cpuShare: Double { system.cpu / 100 }
    var memShare: Double { Double(system.memUsed) / Double(max(system.memTotal, 1)) }

    /// One plain sentence: is the Mac OK, and if not, who's responsible.
    var verdict: (icon: String, color: Color, title: String, detail: String) {
        let topMem = memRows.first { $0.quittable }
        let topCPU = cpuRows.first { $0.quittable }
        if system.pressure >= 4, let m = topMem {
            return ("exclamationmark.octagon.fill", Dusk.coral, L("Bellek dolmak üzere"),
                    L("En çok %@ kullanıyor (%@). Kapatırsan Mac hemen rahatlar.", m.name, m.value))
        }
        if system.pressure >= 2, let m = topMem {
            return ("exclamationmark.triangle.fill", Dusk.orange, L("Bellek zorlanıyor"),
                    L("Mac yavaşlayabilir. En büyük pay %@ uygulamasında (%@).", m.name, m.value))
        }
        if cpuShare >= 0.7, let c = topCPU {
            return ("flame.fill", Dusk.orange, L("İşlemci çok yoğun"),
                    L("%@ işlemcinin %@ kadarını kullanıyor. Pil ve ısınma için kapatmayı düşünebilirsin.", c.name, c.value))
        }
        if cpuShare >= 0.4, let c = topCPU {
            return ("gauge.with.dots.needle.50percent", Dusk.amber, L("Mac biraz meşgul"),
                    L("Şu an en çok %@ çalışıyor (%@). Endişelenecek bir durum yok.", c.name, c.value))
        }
        return ("checkmark.seal.fill", Dusk.green, L("Her şey yolunda"),
                L("Mac rahat çalışıyor. İşlemci %@, bellek %@ / %@.", Self.percent(cpuShare), Fmt.bytes(system.memUsed), Fmt.bytes(system.memTotal)))
    }

    func quit(_ row: Row, force: Bool) {
        if let path = row.bundlePath {
            let running = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == path }
            if !running.isEmpty {
                for r in running { if force { r.forceTerminate() } else { r.terminate() } }
                return
            }
        }
        row.pids.forEach { kill($0, force ? SIGKILL : SIGTERM) }
    }
}
