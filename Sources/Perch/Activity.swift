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
    enum Sort: String, CaseIterable { case cpu = "İşlemci", memory = "Bellek" }

    @Published var sort: Sort = .cpu { didSet { resort() } }
    @Published private(set) var top: [AppLoad] = []
    private var apps: [AppLoad] = []
    @Published private(set) var system = SystemLoad()
    @Published private(set) var ready = false
    private let sampler = ProcessSampler()
    private let queue = DispatchQueue(label: "perch.activity", qos: .utility)
    private var timer: Timer?

    private func resort() {
        let sorted = sort == .cpu
            ? apps.sorted { $0.cpu == $1.cpu ? $0.memory > $1.memory : $0.cpu > $1.cpu }
            : apps.sorted { $0.memory > $1.memory }
        top = Array(sorted.prefix(25))
    }

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
                self.resort()
                self.system = system
                if !self.ready { self.ready = apps.contains { $0.cpu > 0 } || self.timer != nil }
            }
        }
    }

    func quit(_ app: AppLoad, force: Bool) {
        if let path = app.bundlePath {
            let running = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == path }
            if !running.isEmpty {
                for r in running { if force { r.forceTerminate() } else { r.terminate() } }
                return
            }
        }
        app.pids.forEach { kill($0, force ? SIGKILL : SIGTERM) }
    }
}

struct ActivityView: View {
    @ObservedObject var model: ActivityModel
    @State private var confirmForce: AppLoad?

    var body: some View {
        VStack(spacing: 0) {
            header
            summary.padding(.horizontal).padding(.bottom, 12)
            Divider()
            HStack {
                Text("Uygulama")
                Spacer()
                Text("İşlemci").frame(width: 156, alignment: .trailing)
                Text("Bellek").frame(width: 156, alignment: .trailing)
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 26).padding(.vertical, 6)
            List {
                ForEach(model.top) { app in row(app) }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .overlay { if !model.ready { ProgressView() } }
            Divider()
            Text("İşlemci %100 = bir çekirdeğin tamamı (çok çekirdekli uygulamalar %100'ü geçebilir). Sağ tık: uygulamadan çık.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal).padding(.vertical, 10)
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .confirmationDialog("\(confirmForce?.name ?? "") zorla kapatılsın mı?", isPresented: Binding(
            get: { confirmForce != nil }, set: { if !$0 { confirmForce = nil } })) {
            Button("Zorla çık", role: .destructive) { if let a = confirmForce { model.quit(a, force: true) } }
        } message: {
            Text("Kaydedilmemiş değişiklikler kaybolur.")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Etkinlik").font(.title2.bold())
                Text("Şu an Mac'i en çok zorlayan uygulamalar").foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $model.sort) {
                ForEach(ActivityModel.Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 180)
        }
        .padding()
    }

    private var summary: some View {
        let s = model.system
        let memRatio = Double(s.memUsed) / Double(max(s.memTotal, 1))
        let (pressureText, pressureColor): (String, Color) = switch s.pressure {
        case 4: ("Kritik – uygulama kapatmak iyi olur", .red)
        case 2: ("Yüksek – Mac yavaşlayabilir", .orange)
        default: ("Normal", .green)
        }
        return HStack(spacing: 12) {
            gauge(title: "İşlemci", value: "%\(Int(s.cpu.rounded()))", ratio: s.cpu / 100,
                  note: s.cpu >= 80 ? "Çok yoğun" : (s.cpu >= 50 ? "Orta" : "Rahat"),
                  color: s.cpu >= 80 ? .red : (s.cpu >= 50 ? .orange : .accentColor))
            gauge(title: "Bellek", value: "\(Fmt.bytes(s.memUsed)) / \(Fmt.bytes(s.memTotal))", ratio: memRatio,
                  note: "Bellek baskısı: \(pressureText)", color: pressureColor)
        }
    }

    private func gauge(title: String, value: String, ratio: Double, note: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Text(value).font(.callout.weight(.semibold)).monospacedDigit()
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(color).frame(width: max(4, g.size.width * min(1, ratio)))
                }
            }
            .frame(height: 8)
            .animation(.easeOut(duration: 0.4), value: ratio)
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
        .card()
    }

    private func row(_ app: AppLoad) -> some View {
        HStack(spacing: 10) {
            Group {
                if let path = app.bundlePath {
                    AppIconView(path: path, size: 24)
                } else {
                    Image(systemName: "gearshape.2").foregroundStyle(.secondary).frame(width: 24, height: 24)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(app.name).lineLimit(1)
                if app.pids.count > 1 {
                    Text("\(app.pids.count) işlem").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            metric(text: String(format: "%%%.1f", app.cpu), ratio: app.cpu / 100,
                   color: app.cpu >= 80 ? .red : (app.cpu >= 30 ? .orange : .accentColor), highlighted: model.sort == .cpu)
            metric(text: Fmt.bytes(app.memory), ratio: Double(app.memory) / Double(max(model.system.memTotal, 1)) * 4,
                   color: .purple, highlighted: model.sort == .memory)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Çık") { model.quit(app, force: false) }
            Button("Zorla çık…") { confirmForce = app }
            if let path = app.bundlePath {
                Button("Finder'da göster") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            }
        }
    }

    private func metric(text: String, ratio: Double, color: Color, highlighted: Bool) -> some View {
        HStack(spacing: 8) {
            Capsule().fill(Color.primary.opacity(0.08))
                .frame(width: 70, height: 6)
                .overlay(alignment: .leading) {
                    Capsule().fill(color.opacity(highlighted ? 0.85 : 0.4))
                        .frame(width: max(2, 70 * min(1, ratio)), height: 6)
                }
            Text(text).monospacedDigit().fontWeight(highlighted ? .semibold : .regular)
                .frame(width: 78, alignment: .trailing)
        }
    }
}
