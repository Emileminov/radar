// Радар: монитор Mac у Дока (или справа / сверху) - процессор, память, свободное место, топ-3 процесса, очистка кэшей.
import AppKit
import SwiftUI
import Darwin
import Combine
import CoreImage
import ImageIO

// MARK: - Палитра

extension Color {
    init(hex: UInt32) { self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255) }
}
enum Pal {
    static let ok = Color(hex: 0x37D67A)
    static let warn = Color(hex: 0xFFB020)
    static let bad = Color(hex: 0xFF5A5A)
    static let accent = Color(hex: 0xE86E4B)
}

// MARK: - Данные

struct Disk: Identifiable, Equatable {
    let id: String; let name: String; let free: Int64; let total: Int64; let isRoot: Bool
    var freeShare: Double { total > 0 ? Double(free) / Double(total) : 1 }
    var color: Color { (freeShare < 0.10 || free < 20_000_000_000) ? Pal.bad : (freeShare < 0.20 || free < 60_000_000_000) ? Pal.warn : Pal.ok }
}
struct Proc: Identifiable, Equatable { var id: String { name }; let name: String; let cpu: Double; let mem: Int64 }

func fmtBytes(_ b: Int64) -> String {
    let gb = Double(b) / 1_000_000_000
    if gb >= 999.5 { return String(format: "%.1f ТБ", gb / 1000).replacingOccurrences(of: ".", with: ",") }
    if gb >= 10 { return "\(Int(gb.rounded())) ГБ" }
    if gb >= 1 { return String(format: "%.1f ГБ", gb).replacingOccurrences(of: ".", with: ",") }
    return "\(Int((Double(b) / 1_000_000).rounded())) МБ"
}
/// память считаем в двоичных гигабайтах, как Монитор активности (16 ГБ, а не 17)
func fmtMem(_ b: Int64) -> String {
    let gb = Double(b) / 1_073_741_824
    if gb >= 1 { return (gb >= 10 ? String(format: "%.1f ГБ", gb) : String(format: "%.1f ГБ", gb)).replacingOccurrences(of: ".", with: ",").replacingOccurrences(of: ",0 ГБ", with: " ГБ") }
    return "\(Int((Double(b) / 1_048_576).rounded())) МБ"
}
func loadColor(_ v: Double, warn: Double, bad: Double) -> Color { v >= bad ? Pal.bad : v >= warn ? Pal.warn : Pal.ok }

enum Sampler {
    static var prevBusy: UInt64 = 0, prevTotal: UInt64 = 0
    /// загрузка процессора в процентах с прошлого замера
    static func cpu() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) } }
        guard r == KERN_SUCCESS else { return 0 }
        let t = info.cpu_ticks
        let busy = UInt64(t.0) + UInt64(t.1) + UInt64(t.3), total = busy + UInt64(t.2)
        defer { prevBusy = busy; prevTotal = total }
        guard prevTotal > 0, total > prevTotal else { return 0 }
        return Double(busy - prevBusy) / Double(total - prevTotal) * 100
    }
    /// занято памяти как в Мониторе активности: память программ + связанная + сжатая
    static func memory() -> (used: Int64, total: Int64) {
        var s = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &s) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) } }
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        guard r == KERN_SUCCESS else { return (0, total) }
        let page = Int64(vm_kernel_page_size)
        let app = Int64(s.internal_page_count) - Int64(s.purgeable_count)
        let used = (app + Int64(s.wire_count) + Int64(s.compressor_page_count)) * page
        return (min(used, total), total)
    }
    static func disks() -> [Disk] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey, .volumeTotalCapacityKey, .volumeIsRootFileSystemKey, .volumeIsBrowsableKey, .volumeIsRemovableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var out: [Disk] = []
        for u in urls {
            // флешки и карты памяти (съёмные носители) не показываем, только диски
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable != false, v.volumeIsRemovable != true else { continue }
            let total = Int64(v.volumeTotalCapacity ?? 0)
            guard total > 2_000_000_000 else { continue }
            let isRoot = v.volumeIsRootFileSystem == true
            let free = isRoot ? (v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)) : Int64(v.volumeAvailableCapacity ?? 0)
            out.append(Disk(id: u.path, name: isRoot ? "Мак" : (v.volumeName ?? u.lastPathComponent), free: free, total: total, isRoot: isRoot))
        }
        return out.sorted { ($0.isRoot ? 0 : 1, $0.name) < ($1.isRoot ? 0 : 1, $1.name) }
    }
    static let niceNames: [String: String] = ["yandex": "Яндекс", "brave browser": "Brave", "claude": "Claude", "windowserver": "WindowServer (экран)", "kernel_task": "Система", "deleted": "Очистка места (система)", "resolve": "DaVinci Resolve"]
    /// топ процессов, помощники одной программы складываются в неё
    static func topProcs(_ n: Int) -> [Proc] {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-Ao", "pcpu=,rss=,comm="]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        var cpu: [String: Double] = [:], mem: [String: Int64] = [:], label: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let c = Double(parts[0].replacingOccurrences(of: ",", with: ".")), let r = Int64(parts[1]) else { continue }
            let path = String(parts[2])
            var name = (path as NSString).lastPathComponent
            if let app = path.split(separator: "/").first(where: { $0.hasSuffix(".app") }) { name = String(app.dropLast(4)) }
            if name == "ps" { continue }
            let key = name.lowercased()
            let nice = niceNames[key] ?? name
            cpu[nice, default: 0] += c; mem[nice, default: 0] += r * 1024; label[nice] = nice
        }
        // ps считает проценты на одно ядро - переводим в доли всего процессора, как общая цифра
        let cores = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))
        return cpu.sorted { $0.value > $1.value }.prefix(n).map { Proc(name: $0.key, cpu: $0.value / cores, mem: mem[$0.key] ?? 0) }
    }
}

// MARK: - Очистка

enum Cleaner {
    /// папка кэша DaVinci Resolve: настройка davinciCache (defaults write com.emil.radar davinciCache /путь/CacheClip),
    /// иначе стандартное место; если папки нет - кнопка не показывается
    static var davinciCache: URL {
        if let p = UserDefaults.standard.string(forKey: "davinciCache"), !p.isEmpty { return URL(fileURLWithPath: (p as NSString).expandingTildeInPath) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/DaVinci Resolve/CacheClip")
    }
    static let userCaches = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
    /// кэши, которые не трогаем никогда: система, браузеры для рендера, модели, Claude
    static let protected = ["apple", "playwright", "puppeteer", "chrome-headless", "remotion", "hyperframes", "whisper", "huggingface", "torch", "kinocut", "claude", "anthropic", "chelka", "radar", "diktovka", "voxa", "resolve", "blackmagic", "cloudkit", "familycircle", "geod", "siri", "passkit", "gamekit", "cua-driver", "amsdata"]
    static let stopTokens: Set<String> = ["com", "app", "apps", "desktop", "browser", "helper", "mac", "macos", "inc", "software", "the", "and", "org", "net"]

    static func dirSize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey], options: [], errorHandler: { _, _ in true }) else { return 0 }
        var s: Int64 = 0
        for case let f as URL in e { if let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]) { s += Int64(v.totalFileAllocatedSize ?? 0) } }
        return s
    }
    /// слова, по которым узнаём кэш открытой программы
    static func runningTokens() -> Set<String> {
        var t = Set<String>()
        for a in NSWorkspace.shared.runningApplications {
            for part in (a.bundleIdentifier ?? "").lowercased().split(whereSeparator: { ".-_ ".contains($0) }) where part.count >= 4 && !stopTokens.contains(String(part)) { t.insert(String(part)) }
            if let w = a.localizedName?.lowercased().split(separator: " ").first, w.count >= 4, !stopTokens.contains(String(w)) { t.insert(String(w)) }
        }
        return t
    }
    /// кэши закрытых программ
    static func idleAppCaches() -> [URL] {
        let tokens = runningTokens()
        let items = (try? FileManager.default.contentsOfDirectory(at: userCaches, includingPropertiesForKeys: nil)) ?? []
        return items.filter { u in
            let n = u.lastPathComponent.lowercased()
            if protected.contains(where: { n.contains($0) }) { return false }
            if tokens.contains(where: { n.contains($0) }) { return false }
            return true
        }
    }
    static func davinciSize() -> Int64? { FileManager.default.fileExists(atPath: davinciCache.path) ? dirSize(davinciCache) : nil }
    static func appCachesSize() -> Int64 { idleAppCaches().reduce(0) { $0 + dirSize($1) } }
    static func clearContents(of dirs: [URL]) -> Int64 {
        var freed: Int64 = 0
        for d in dirs {
            let size = dirSize(d)
            if (try? FileManager.default.removeItem(at: d)) != nil { freed += size }
        }
        return freed
    }
    static func clearDavinci() -> Int64 {
        let items = (try? FileManager.default.contentsOfDirectory(at: davinciCache, includingPropertiesForKeys: nil)) ?? []
        return clearContents(of: items)
    }
}

// MARK: - Модель

final class Model: ObservableObject {
    @Published var cpu: Double = 0
    @Published var memUsed: Int64 = 0
    @Published var memTotal: Int64 = 1
    @Published var disks: [Disk] = []
    @Published var procs: [Proc] = []
    @Published var expanded = false
    @Published var davinciCache: Int64?
    @Published var appCache: Int64?
    @Published var status: String?
    @Published var detailsH: CGFloat = 0
    @Published var rowW: CGFloat = 0
    @Published var originX: CGFloat = 0
    @Published var colW: CGFloat = 0
    @Published var dockH: CGFloat = 54
    @Published var colH: CGFloat = 0
    var memShare: Double { Double(memUsed) / Double(max(memTotal, 1)) * 100 }
    var cleaning = false
}

// MARK: - Вид

struct Material: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView { let v = NSVisualEffectView(); v.material = .menu; v.blendingMode = .behindWindow; v.state = .active; return v }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

/// варианты фона капсулы (выбор пользователя хранится в настройках, ключ bgStyle)
/// гибридные фоны: в полосе строки меню прозрачно, ниже - системное размытие того, что лежит за окном
enum Hybrid {
    static let materials: [Int: NSVisualEffectView.Material] = [201: .hudWindow, 202: .menu, 203: .popover, 204: .fullScreenUI, 205: .underWindowBackground, 206: .sheet, 207: .windowBackground]
}
enum Backdrop {
    static let materials: [Int: NSVisualEffectView.Material] = [11: .windowBackground, 3: .menu, 4: .titlebar, 5: .headerView, 6: .hudWindow, 7: .fullScreenUI, 8: .underWindowBackground, 9: .sheet, 10: .popover]
    static var current: Int { let v = UserDefaults.standard.integer(forKey: "bgStyle"); return v == 0 ? 207 : v }
}
struct FX: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView { let v = NSVisualEffectView(); v.material = material; v.blendingMode = .behindWindow; v.state = .active; return v }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}
/// фон как у строки меню: кусок обоев под капсулой, размытый и чуть затемнённый
struct WallParams: Hashable { let blur: Double; let dark: Double; let sat: Double }
enum Wall {
    static let presets: [Int: WallParams] = [
        101: .init(blur: 30, dark: 0.00, sat: 1.0), 102: .init(blur: 30, dark: 0.15, sat: 1.0), 103: .init(blur: 30, dark: 0.30, sat: 1.0),
        104: .init(blur: 60, dark: 0.00, sat: 1.0), 105: .init(blur: 60, dark: 0.15, sat: 1.0), 106: .init(blur: 60, dark: 0.30, sat: 1.0),
        107: .init(blur: 60, dark: 0.15, sat: 1.4), 108: .init(blur: 100, dark: 0.20, sat: 1.3)]
    static var cache: [WallParams: NSImage] = [:]
    static var key = ""
    /// текущий файл обоев и кадр (у динамических обоев - тёмный или светлый)
    static func source() -> (URL, Int)? {
        guard let scr = NSScreen.screens.first, let url = NSWorkspace.shared.desktopImageURL(for: scr) else { return nil }
        var idx = 0
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil), let m = CGImageSourceCopyMetadataAtIndex(src, 0, nil) {
            for tagName in ["apple_desktop:solar", "apple_desktop:h24", "apple_desktop:apr"] {
                if let t = CGImageMetadataCopyTagWithPath(m, nil, tagName as CFString), let v = CGImageMetadataTagCopyValue(t) as? String,
                   let d = Data(base64Encoded: v), let pl = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any],
                   let ap = pl["ap"] as? [String: Any] {
                    let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    idx = (ap[dark ? "d" : "l"] as? Int) ?? 0
                    break
                }
            }
        }
        return (url, idx)
    }
    /// полоса обоев по верхнему краю экрана (во всю ширину), уже размытая
    static func strip(_ p: WallParams, height: CGFloat = 720) -> NSImage? {
        guard let scr = NSScreen.screens.first, let (url, idx) = source() else { return nil }
        let k = "\(url.path)#\(idx)#\(scr.frame.size)"
        if k != key { cache = [:]; key = k }
        if let c = cache[p] { return c }
        let scale = scr.backingScaleFactor
        let sw = scr.frame.width * scale, sh = scr.frame.height * scale
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, idx, nil) as? [CFString: Any],
              let iw = props[kCGImagePropertyPixelWidth] as? CGFloat, let ih = props[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
        let fill = max(sw / iw, sh / ih)
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: Int((max(iw, ih) * fill).rounded(.up)), kCGImageSourceCreateThumbnailWithTransform: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, idx, opts as CFDictionary) else { return nil }
        let tw = CGFloat(cg.width), th = CGFloat(cg.height)
        let s2 = max(sw / tw, sh / th)
        // обои «заполняют» экран и стоят по центру, как в настройках «Заполнение»
        var ci = CIImage(cgImage: cg).transformed(by: CGAffineTransform(scaleX: s2, y: s2))
        ci = ci.transformed(by: CGAffineTransform(translationX: (sw - tw * s2) / 2, y: (sh - th * s2) / 2))
        let hpx = height * scale
        let rect = CGRect(x: 0, y: sh - hpx, width: sw, height: hpx)
        ci = ci.clampedToExtent().applyingGaussianBlur(sigma: p.blur * scale / 2).cropped(to: rect)
        if p.sat != 1 { ci = ci.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: p.sat]) }
        if p.dark > 0 { ci = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: p.dark)).cropped(to: rect).composited(over: ci) }
        guard let out = CIContext().createCGImage(ci, from: rect) else { return nil }
        let img = NSImage(cgImage: out, size: NSSize(width: scr.frame.width, height: height))
        cache[p] = img
        return img
    }
}
struct WallBackdrop: View {
    let image: NSImage; let originX: CGFloat
    var body: some View {
        GeometryReader { g in
            Image(nsImage: image).resizable().frame(width: image.size.width, height: image.size.height)
                .offset(x: -originX)
                .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
                .clipped()
        }
    }
}

struct Glass: ViewModifier {
    let shape: UnevenRoundedRectangle; let plain: Bool; var style: Int = Backdrop.current; var originX: CGFloat = 0; var topFade: CGFloat = 0
    @ViewBuilder func body(content: Content) -> some View {
        if plain { content.background(Color(hex: 0x15161C), in: shape) }
        else if style >= 201 && style <= 208 {
            let mask = VStack(spacing: 0) {
                Color.clear.frame(height: topFade)
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 10)
                Color.black
            }
            if let mat = Hybrid.materials[style] {
                content.background(FX(material: mat).clipShape(shape).mask(mask))
            } else if #available(macOS 26.0, *) {
                content.background(Color.clear.glassEffect(.clear, in: shape).mask(mask))
            } else { content.background(FX(material: .hudWindow).clipShape(shape).mask(mask)) }
        }
        else if let p = Wall.presets[style], let img = Wall.strip(p) {
            // в полосе строки меню свой фон не рисуем - там видна настоящая строка, без границ;
            // ниже фон плавно проявляется и становится сплошным
            content.background(WallBackdrop(image: img, originX: originX).clipShape(shape).mask(
                VStack(spacing: 0) {
                    LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .clear, location: 0.35), .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom)
                        .frame(height: topFade)
                    Color.black
                }))
        }
        else if let mat = Backdrop.materials[style] { content.background(FX(material: mat).clipShape(shape)) }
        else if #available(macOS 26.0, *) {
            switch style {
            case 2, 22: content.glassEffect(.clear, in: shape)
            case 23: content.glassEffect(.regular.tint(.black.opacity(0.15)), in: shape)
            case 24: content.glassEffect(.regular.tint(.black.opacity(0.30)), in: shape)
            case 25: content.glassEffect(.clear.tint(.black.opacity(0.20)), in: shape)
            case 26: content.glassEffect(.clear.tint(.black.opacity(0.35)), in: shape)
            case 45: content.glassEffect(.clear.tint(.black.opacity(0.10)), in: shape)
            case 300...399: content.glassEffect(.clear.tint(.black.opacity(Double(style - 300) / 100)), in: shape)
            case 31...39: content.glassEffect(.clear.tint(.black.opacity(Double(style - 31) * 0.1 + 0.2)), in: shape)
            default: content.glassEffect(.regular, in: shape)
            }
        }
        else { content.background(FX(material: .menu).clipShape(shape)) }
    }
}

/// светлая кромка по верхнему краю, как блик на стекле Дока
struct TopHighlight: ViewModifier {
    let shape: UnevenRoundedRectangle
    func body(content: Content) -> some View {
        // как у Дока (замер по пикселям): снаружи тёмная линия 1 px, под ней мягкий блик ~ (85,93,99), не ярче
        content.overlay(
            ZStack {
                // тёмная линия только сверху (снизу у Дока её нет)
                shape.strokeBorder(LinearGradient(stops: [.init(color: .black.opacity(0.9), location: 0), .init(color: .black.opacity(0.0), location: 0.35)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                // блик: сверху ~ +60 к фону, снизу светлая кромка ~ +45, посередине нет
                shape.inset(by: 1).strokeBorder(LinearGradient(stops: [.init(color: .white.opacity(0.26), location: 0), .init(color: .white.opacity(0.05), location: 0.3), .init(color: .white.opacity(0.0), location: 0.55), .init(color: .white.opacity(0.20), location: 1)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
            .allowsHitTesting(false))
    }
}

/// стили иконок (настройка iconStyle): 1 - точки и контуры, 2 - заливные значки, 3 - кольца-индикаторы, 4 - плашки
enum IconKind { case cpu, mem, disk(root: Bool) }
struct StatIcon: View {
    let kind: IconKind; let color: Color; let share: Double   // share - заполненность 0...1 (для дисков - занято)
    var style: Int = UserDefaults.standard.integer(forKey: "iconStyle") == 0 ? 3 : UserDefaults.standard.integer(forKey: "iconStyle")
    var symbol: String {
        switch kind {
        case .cpu: return "cpu"
        case .mem: return "memorychip"
        case .disk(let root): return root ? "desktopcomputer" : "externaldrive"
        }
    }
    /// заливная версия значка; у компьютера её нет - берём обычный
    var filled: String { if case .disk(true) = kind { return "desktopcomputer" }; return symbol + ".fill" }
    var body: some View {
        switch style {
        case 2:
            Image(systemName: filled).font(.system(size: 18, weight: .semibold))
                .symbolRenderingMode(.hierarchical).foregroundStyle(color)
        case 3:
            ZStack {
                Circle().stroke(Color.primary.opacity(0.16), lineWidth: 3.5)
                Circle().trim(from: 0, to: max(0.02, min(1, share))).stroke(color, style: StrokeStyle(lineWidth: 3.5, lineCap: .round)).rotationEffect(.degrees(-90))
                Image(systemName: symbol).font(.system(size: 8.5, weight: .bold)).foregroundStyle(color)
            }.frame(width: 22, height: 22)
        case 4:
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.gradient)
                .frame(width: 24, height: 24)
                .overlay(Image(systemName: filled).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white))
        default:
            switch kind {
            case .cpu, .mem: Circle().fill(color).frame(width: 11, height: 11)
            case .disk(let root): Image(systemName: root ? "desktopcomputer" : "externaldrive").font(.system(size: 17, weight: .semibold)).foregroundStyle(color)
            }
        }
    }
}

struct Dot: View { let color: Color; var body: some View { Circle().fill(color).frame(width: 11, height: 11) } }

struct Bar: View {
    let share: Double; let color: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.14))
                Capsule().fill(color).frame(width: max(4, g.size.width * min(1, share)))
            }
        }.frame(height: 6)
    }
}

/// ячейка строки: крупное значение и подпись под ним
struct Cell<Icon: View>: View {
    let icon: Icon; let value: String; let label: String
    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 6) { icon; Text(value).font(.system(size: 18, weight: .semibold)).monospacedDigit() }
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
        }.frame(minWidth: 70)
    }
}

struct HKey: PreferenceKey { static var defaultValue: CGFloat = 0; static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) } }
struct WKey: PreferenceKey { static var defaultValue: CGFloat = 0; static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) } }

struct NotchView: View {
    @ObservedObject var m: Model
    let barH: CGFloat
    var plain = false
    let onToggle: () -> Void
    let onClean: (CleanKind) -> Void

    static let minW: CGFloat = 460

    var row: some View {
        HStack(spacing: 20) {
            Cell(icon: StatIcon(kind: .cpu, color: loadColor(m.cpu, warn: 50, bad: 80), share: m.cpu / 100), value: "\(Int(m.cpu.rounded()))%", label: "Процессор")
            Cell(icon: StatIcon(kind: .mem, color: loadColor(m.memShare, warn: 75, bad: 90), share: m.memShare / 100), value: "\(Int(m.memShare.rounded()))%", label: "Память")
            Rectangle().fill(Color.primary.opacity(0.18)).frame(width: 0.5, height: 30)
            ForEach(m.disks) { d in
                Cell(icon: StatIcon(kind: .disk(root: d.isRoot), color: d.color, share: 1 - d.freeShare),
                     value: fmtBytes(d.free), label: d.name)
            }
        }
        .fixedSize()
        .background(GeometryReader { g in Color.clear.preference(key: WKey.self, value: g.size.width) })
    }

    var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            if barH > 0 { Divider().opacity(0.5) }
            VStack(alignment: .leading, spacing: 5) {
                HStack { Text("Процессор"); Spacer(); Text("\(Int(m.cpu.rounded()))%") }
                Bar(share: m.cpu / 100, color: loadColor(m.cpu, warn: 50, bad: 80))
                HStack { Text("Память"); Spacer(); Text("\(fmtMem(m.memUsed)) из \(fmtMem(m.memTotal))") }.padding(.top, 4)
                Bar(share: m.memShare / 100, color: loadColor(m.memShare, warn: 75, bad: 90))
            }
            Divider().opacity(0.5)
            Text("Свободно на дисках").font(.system(size: 12)).foregroundStyle(.secondary)
            ForEach(m.disks) { d in
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text(d.name); Spacer(); Text("\(fmtBytes(d.free)) из \(fmtBytes(d.total))").foregroundStyle(d.color) }
                    Bar(share: 1 - d.freeShare, color: d.color)
                }
            }
            Divider().opacity(0.5)
            Text("Больше всех едят").font(.system(size: 12)).foregroundStyle(.secondary)
            ForEach(Array(m.procs.enumerated()), id: \.element.id) { i, p in
                HStack {
                    Text(p.name).lineLimit(1)
                    Spacer()
                    Text("\(Int(p.cpu.rounded()))%").frame(width: 52, alignment: .trailing)
                    Text(fmtMem(p.mem)).frame(width: 74, alignment: .trailing)
                }.foregroundStyle(i == 0 ? Pal.accent : Color.primary)
            }
            if m.procs.isEmpty { Text("Считаю…").foregroundStyle(.secondary) }
            Divider().opacity(0.5)
            Text("Очистка без закрытия программ").font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                if let s = m.davinciCache { CleanButton(title: "Кэш DaVinci", size: s) { onClean(.davinci) } }
                CleanButton(title: "Кэши программ", size: m.appCache) { onClean(.apps) }
            }
            if let s = m.status { Text(s).font(.system(size: 12)).foregroundStyle(Pal.ok) }
        }
        .font(.system(size: 13)).monospacedDigit()
        .padding(.bottom, 18)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { g in Color.clear.preference(key: HKey.self, value: g.size.height) })
    }

    var body: some View {
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: 24, bottomTrailingRadius: 24)
        let width = max(m.rowW + 52, Self.minW)
        VStack(spacing: 0) {
            row.frame(width: width, height: barH)
            details.padding(.horizontal, 26).frame(width: width)
                .opacity(m.expanded ? 1 : 0)
        }
        .frame(width: width, height: m.expanded ? barH + m.detailsH : barH, alignment: .top)
        .clipped()
        .contentShape(shape)
        .onTapGesture { onToggle() }
        .modifier(Glass(shape: shape, plain: plain, originX: m.originX, topFade: (barH / 2).rounded()))
        .onPreferenceChange(HKey.self) { h in if abs(h - m.detailsH) > 0.5 { m.detailsH = h } }
        .onPreferenceChange(WKey.self) { w in if abs(w - m.rowW) > 0.5 { m.rowW = w } }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct SideKey: PreferenceKey { static var defaultValue: CGSize = .zero; static func reduce(value: inout CGSize, nextValue: () -> CGSize) { let n = nextValue(); value = CGSize(width: max(value.width, n.width), height: max(value.height, n.height)) } }

/// вертикальная панель у правого края экрана: столбик с цифрами, по щелчку слева выезжают подробности
struct SideView: View {
    @ObservedObject var m: Model
    var plain = false
    let onToggle: () -> Void
    let onClean: (CleanKind) -> Void
    static let detailsW: CGFloat = 440

    var column: some View {
        VStack(spacing: 18) {
            Cell(icon: StatIcon(kind: .cpu, color: loadColor(m.cpu, warn: 50, bad: 80), share: m.cpu / 100), value: "\(Int(m.cpu.rounded()))%", label: "Процессор")
            Cell(icon: StatIcon(kind: .mem, color: loadColor(m.memShare, warn: 75, bad: 90), share: m.memShare / 100), value: "\(Int(m.memShare.rounded()))%", label: "Память")
            Rectangle().fill(Color.primary.opacity(0.18)).frame(width: 44, height: 0.5)
            ForEach(m.disks) { d in
                Cell(icon: StatIcon(kind: .disk(root: d.isRoot), color: d.color, share: 1 - d.freeShare),
                     value: fmtBytes(d.free), label: d.name)
            }
        }
        .padding(.vertical, 22).padding(.horizontal, 16)
        .fixedSize()
        .background(GeometryReader { g in Color.clear.preference(key: SideKey.self, value: g.size) })
    }

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 22, bottomLeadingRadius: 22)
        let h = m.expanded ? max(m.colH, m.detailsH + 30) : m.colH
        HStack(spacing: 0) {
            NotchView(m: m, barH: 0, onToggle: {}, onClean: onClean).details
                .padding(.top, 12)
                .frame(width: Self.detailsW - 40)
                .padding(.leading, 26).padding(.trailing, 14)
                .frame(width: m.expanded ? Self.detailsW : 0, alignment: .leading)
                .clipped()
                .opacity(m.expanded ? 1 : 0)
            column
        }
        .frame(height: h)
        .clipped()
        .contentShape(shape)
        .onTapGesture { onToggle() }
        .modifier(Glass(shape: shape, plain: plain, style: 11))
        .onPreferenceChange(HKey.self) { v in if abs(v - m.detailsH) > 0.5 { m.detailsH = v } }
        .onPreferenceChange(SideKey.self) { v in
            if abs(v.width - m.colW) > 0.5 { m.colW = v.width }
            if abs(v.height - m.colH) > 0.5 { m.colH = v.height }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }
}

/// у Дока: строка с цифрами той же высоты, что Док; по щелчку подробности выезжают вверх
struct DockView: View {
    @ObservedObject var m: Model
    var plain = false
    let onToggle: () -> Void
    let onClean: (CleanKind) -> Void
    var onDrag: (Bool) -> Void = { _ in }
    static let minW: CGFloat = 440
    static var glassStyle: Int { let v = UserDefaults.standard.integer(forKey: "dockGlass"); return v == 0 ? 45 : v }
    /// свёрнутая - ровно по содержимому (сколько дисков, столько и места); раскрытая - не уже, чем нужно подробностям
    static func width(_ m: Model, open: Bool) -> CGFloat { (open ? max(m.rowW + 44, minW) : m.rowW + 44).rounded(.up) }

    var body: some View {
        // скругление как у Дока: около четверти его высоты
        let r = (m.dockH * 0.27).rounded()
        let shape = UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: r, bottomTrailingRadius: r, topTrailingRadius: r)
        let rowH = m.dockH
        let w = Self.width(m, open: m.expanded)
        let base = NotchView(m: m, barH: 0, onToggle: {}, onClean: onClean)
        VStack(spacing: 0) {
            base.details
                .padding(.top, 18).padding(.horizontal, 24)
                .frame(width: w)
                .frame(height: m.expanded ? m.detailsH + 18 : 0, alignment: .top)
                .clipped()
                .opacity(m.expanded ? 1 : 0)
            base.row.frame(width: w, height: rowH)
        }
        .contentShape(shape)
        .onTapGesture { onToggle() }
        // тянешь вбок - едет вдоль низа экрана; короткий щелчок раскрывает
        .gesture(DragGesture(minimumDistance: 5, coordinateSpace: .global)
            .onChanged { _ in onDrag(false) }
            .onEnded { _ in onDrag(true) })
        .modifier(Glass(shape: shape, plain: plain, style: DockView.glassStyle))   // прозрачное стекло с затемнением 40% - замерено по цвету Дока
        .modifier(TopHighlight(shape: shape))   // тонкий блик по верхнему краю, как у Дока
        .onPreferenceChange(HKey.self) { v in if abs(v - m.detailsH) > 0.5 { m.detailsH = v } }
        .onPreferenceChange(WKey.self) { v in if abs(v - m.rowW) > 0.5 { m.rowW = v } }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }
}

struct CleanButton: View {
    let title: String; let size: Int64?; let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                Text(title)
                Text(size.map(fmtBytes) ?? "…").foregroundStyle(.secondary)
            }
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(Color.primary.opacity(0.10)))
        }.buttonStyle(.plain)
    }
}

enum CleanKind { case davinci, apps }

// MARK: - Окно

final class Container: NSView {
    override func rightMouseDown(with e: NSEvent) { if let m = menu { NSMenu.popUpContextMenu(m, with: e, for: self) } }
}

/// окно Радара никогда не становится активным: иначе системное стекло меняет оттенок при каждом щелчке
final class Panel: NSPanel { override var canBecomeKey: Bool { false }; override var canBecomeMain: Bool { false } }

/// стекло всегда в «активном» виде, как у Дока, независимо от того, где щёлкнули
struct AlwaysActive: ViewModifier {
    func body(content: Content) -> some View {
        // «нормальный» цвет - как у неактивного окна (так оно совпадает с Доком); окно активным не становится, цвет не прыгает
        content
    }
}

final class App: NSObject, NSApplicationDelegate {
    let model = Model()
    var panel: Panel!
    var host: NSHostingView<AnyView>!
    var container: Container!
    var tick = 0
    var closing = false
    var lastDockH: CGFloat = 0
    var bag: AnyCancellable?
    var outsideMonitor: Any?
    var lastCacheScan = Date.distantPast
    let bg = DispatchQueue(label: "radar.bg", qos: .utility)

    var screen: NSScreen { NSScreen.screens.first ?? NSScreen.main! }
    var menuBarHeight: CGFloat { let s = screen; let h = s.frame.maxY - s.visibleFrame.maxY; return h > 0 ? h : 30 }
    /// высота свёрнутой капсулы - две строки меню
    var barH: CGFloat { (menuBarHeight * 2).rounded() }

    /// раскладка: справа экрана (по умолчанию) или сверху по центру
    var layout: String { UserDefaults.standard.string(forKey: "layout") ?? "dock" }
    var side: Bool { layout == "side" }
    var top: Bool { layout == "top" }
    /// высота полосы Дока (если он спрятан - по размеру значков)
    var dockH: CGFloat {
        let reserved = screen.visibleFrame.minY - screen.frame.minY
        if reserved > 20 { return (reserved - 4).rounded() }
        let tile = UserDefaults(suiteName: "com.apple.dock")?.double(forKey: "tilesize") ?? 48
        return CGFloat((tile > 0 ? tile : 48) + 16).rounded()
    }

    func makeView() -> AnyView { AnyView(makeLayoutView().modifier(AlwaysActive())) }
    func makeLayoutView() -> AnyView {
        let toggle: () -> Void = { [weak self] in self?.toggle() }
        let clean: (CleanKind) -> Void = { [weak self] k in self?.clean(k) }
        switch layout {
        case "side": return AnyView(SideView(m: model, onToggle: toggle, onClean: clean))
        case "top": return AnyView(NotchView(m: model, barH: barH, onToggle: toggle, onClean: clean))
        default: return AnyView(DockView(m: model, onToggle: toggle, onClean: clean, onDrag: { [weak self] end in self?.dockDrag(end) }))
        }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 500, height: barH), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = top ? .popUpMenu : .statusBar   // сверху - выше строки меню, чтобы щелчок по верхней половине доходил до Радара
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        panel.isMovable = false; panel.hidesOnDeactivate = false

        host = NSHostingView(rootView: makeView())
        container = Container()
        container.addSubview(host)
        host.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo: container.leadingAnchor), host.trailingAnchor.constraint(equalTo: container.trailingAnchor), host.topAnchor.constraint(equalTo: container.topAnchor), host.bottomAnchor.constraint(equalTo: container.bottomAnchor)])
        container.menu = makeMenu()
        panel.contentView = container

        _ = Sampler.cpu()
        model.disks = Sampler.disks()
        model.dockH = dockH
        relayout()
        panel.orderFrontRegardless()

        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.sample() }
        bag = model.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.relayout() } }
        // щелчок мимо Радара сворачивает её
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, !self.model.cleaning else { return }
            // щелчок в верхней полосе может уйти строке меню - если он пришёлся на Радар, считаем его своим
            // щелчок мимо Радара сворачивает её; щелчки по верхней полосе ловит системный перехват (installTap)
            let inside = self.panel.frame.contains(NSEvent.mouseLocation)
            if self.model.expanded && !inside { self.toggle() }
        }
        installTap()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.syncDockHeight(); self?.relayout() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in self?.model.disks = Sampler.disks() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in self?.model.disks = Sampler.disks() }
    }

    func sample() {
        tick += 1
        let c = Sampler.cpu(); let mem = Sampler.memory()
        if abs(c - model.cpu) >= 0.5 { model.cpu = c }
        if mem.used != model.memUsed { model.memUsed = mem.used; model.memTotal = mem.total }
        syncDockHeight()
        if tick % 5 == 0 {
            let d = Sampler.disks(); if d != model.disks { model.disks = d }
        }
        if model.expanded { refreshProcs() }
    }

    func refreshProcs() {
        bg.async { let p = Sampler.topProcs(3); DispatchQueue.main.async { if p != self.model.procs { self.model.procs = p } } }
    }

    func refreshCacheSizes(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastCacheScan) > 600 else { return }   // перебор файлов кэша тяжёлый - не чаще раза в 10 минут
        lastCacheScan = Date()
        bg.async {
            let d = Cleaner.davinciSize(); let a = Cleaner.appCachesSize()
            DispatchQueue.main.async { self.model.davinciCache = d; self.model.appCache = a }
        }
    }

    /// по щелчку капсула плавно выезжает вниз, повторный щелчок - уезжает обратно.
    /// Окно сначала вырастает до полного размера (прозрачное), потом внутри едет капсула - без рывков.
    var lastToggle = Date.distantPast
    var tap: CFMachPort?

    /// Верхнюю полосу Радара забирает строка меню, и окно щелчок не получает.
    /// Поэтому слушаем щелчки на уровне системы (только слушаем, ничего не меняем) - нужно право «Мониторинг ввода».
    func installTap() {
        if !CGPreflightListenEventAccess() { CGRequestListenEventAccess() }
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
        let cb: CGEventTapCallBack = { _, type, ev, refcon in
            guard let r = refcon else { return Unmanaged.passUnretained(ev) }
            let app = Unmanaged<App>.fromOpaque(r).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = app.tap { CGEvent.tapEnable(tap: t, enable: true) }
            } else if type == .leftMouseDown {
                let p = ev.location
                DispatchQueue.main.async { app.tapClick(p) }
            }
            return Unmanaged.passUnretained(ev)
        }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask, callback: cb, userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let t = tap {
            CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
            CGEvent.tapEnable(tap: t, enable: true)
        } else {
            // права ещё нет - пробуем снова, пока его не включат
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.installTap() }
        }
    }
    func tapClick(_ cg: CGPoint) {
        let primaryH = NSScreen.screens[0].frame.height
        let p = NSPoint(x: cg.x, y: primaryH - cg.y)
        guard top else { return }
        let f = panel.frame
        // включаем и самый верхний край экрана (y == maxY), иначе щелчок на границе не считается
        let top = screen.frame.maxY
        if p.x >= f.minX && p.x <= f.maxX && p.y >= top - menuBarHeight && p.y <= top + 2 { toggle() }
    }

    func toggle() {
        // один щелчок может прийти и в окно, и через перехват - считаем его один раз
        guard Date().timeIntervalSince(lastToggle) > 0.3 else { return }
        lastToggle = Date()
        if model.expanded {
            closing = true
            withAnimation(.spring(response: 0.34, dampingFraction: 0.92)) { model.expanded = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self = self, !self.model.expanded else { return }
                self.closing = false; self.relayout()
            }
        } else {
            refreshProcs(); refreshCacheSizes()
            closing = false
            switch layout {
            case "side": setSideFrame(open: true)
            case "top": setFrame(height: barH + model.detailsH + 40)
            default: setDockFrame(open: true)
            }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { model.expanded = true }
        }
    }

    func relayout() {
        if side { setSideFrame(open: model.expanded || closing); return }
        if !top { setDockFrame(open: model.expanded || closing); return }
        let h = (model.expanded || closing) ? barH + model.detailsH + 40 : barH
        setFrame(height: h)
    }

    /// высота Дока поменялась - подстраиваемся (каждые 2 секунды и при изменении экрана)
    func syncDockHeight() {
        let h = dockH
        if abs(h - model.dockH) > 0.5 { model.dockH = h }
    }

    /// у Дока: на одной линии с ним, по умолчанию в правом углу; место можно перетащить, оно запоминается
    var dragStart: (mouse: CGFloat, win: CGFloat)?
    func dockX(width w: CGFloat) -> CGFloat {
        let s = screen.frame
        let saved = UserDefaults.standard.object(forKey: "dockX") as? Double
        let x = saved.map { s.minX + CGFloat($0) } ?? (s.maxX - w - 10)
        return min(max(x, s.minX + 6), s.maxX - w - 6).rounded()
    }
    func setDockFrame(open: Bool) {
        let wc = DockView.width(model, open: false)
        let w = DockView.width(model, open: open)
        let h = (model.dockH + (open ? model.detailsH + 18 : 0)).rounded(.up)
        // раскрытая растёт влево: правый край остаётся на месте
        let s = screen.frame
        let x = dragStart != nil ? panel.frame.minX : max(s.minX + 6, dockX(width: wc) + wc - w)
        let f = NSRect(x: x, y: s.minY + 4, width: w, height: h)
        if f != panel.frame { panel.setFrame(f, display: true) }
    }
    func dockDrag(_ ended: Bool) {
        let s = screen.frame
        let mx = NSEvent.mouseLocation.x
        if dragStart == nil { dragStart = (mx, panel.frame.minX) }
        guard let st = dragStart else { return }
        let w = panel.frame.width
        let x = min(max(st.win + mx - st.mouse, s.minX + 6), s.maxX - w - 6).rounded()
        var f = panel.frame; f.origin.x = x
        panel.setFrame(f, display: true)
        if ended {
            // запоминаем левый край свёрнутого вида (правый край общий для обоих видов)
            let wc = DockView.width(model, open: false)
            UserDefaults.standard.set(Double(x + w - wc - s.minX), forKey: "dockX")
            dragStart = nil
            lastToggle = Date()   // отпускание после перетаскивания не считаем щелчком
        }
    }

    /// боковая панель прижата к правому краю экрана, по центру высоты; растёт влево
    func setSideFrame(open: Bool) {
        let w = (model.colW + (open ? SideView.detailsW : 0)).rounded(.up)
        let h = (open ? max(model.colH, model.detailsH + 30) : model.colH).rounded(.up)
        guard w > 0, h > 0 else { return }
        let s = screen.frame, v = screen.visibleFrame
        let f = NSRect(x: s.maxX - w, y: (v.midY - h / 2).rounded(), width: w, height: h)
        if f != panel.frame { panel.setFrame(f, display: true) }
    }

    func setFrame(height: CGFloat) {
        let w = max(model.rowW + 52, NotchView.minW).rounded(.up)
        let s = screen.frame
        let f = NSRect(x: (s.midX - w / 2).rounded(), y: s.maxY - height, width: w, height: height)
        if f != panel.frame { panel.setFrame(f, display: true) }
        let ox = f.minX - s.minX
        if ox != model.originX { model.originX = ox }
    }

    func clean(_ kind: CleanKind) {
        model.cleaning = true
        defer { model.cleaning = false }
        let a = NSAlert()
        switch kind {
        case .davinci:
            a.messageText = "Очистить кэш DaVinci?"
            a.informativeText = "Удалю \(model.davinciCache.map(fmtBytes) ?? "кэш") из \(Cleaner.davinciCache.path). Проекты и исходники не трогаю, DaVinci сам пересоздаст кэш, когда понадобится."
        case .apps:
            a.messageText = "Очистить кэши программ?"
            a.informativeText = "Удалю \(model.appCache.map(fmtBytes) ?? "кэши") кэшей только тех программ, которые сейчас закрыты. Открытые программы, система и инструменты рендера не трогаются. Программы сами создадут кэш заново."
        }
        a.addButton(withTitle: "Очистить"); a.addButton(withTitle: "Отмена")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        model.status = "Чищу…"
        bg.async {
            let freed = kind == .davinci ? Cleaner.clearDavinci() : Cleaner.clearContents(of: Cleaner.idleAppCaches())
            DispatchQueue.main.async {
                self.model.status = "Освобождено \(fmtBytes(freed))"
                self.model.disks = Sampler.disks()
                self.refreshCacheSizes(force: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.model.status = nil }
            }
        }
    }

    // MARK: меню по правому клику и автозапуск
    let agentURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/com.emil.radar.plist")
    var autostart: Bool { FileManager.default.fileExists(atPath: agentURL.path) }

    func makeMenu() -> NSMenu {
        let m = NSMenu()
        let auto = NSMenuItem(title: "Запускать вместе с системой", action: #selector(toggleAutostart), keyEquivalent: ""); auto.target = self
        auto.state = autostart ? .on : .off
        m.addItem(auto)
        m.addItem(.separator())
        for (key, title) in [("dock", "Внизу у Дока"), ("side", "Справа экрана"), ("top", "Сверху по центру")] {
            let it = NSMenuItem(title: title, action: #selector(switchLayout(_:)), keyEquivalent: ""); it.target = self
            it.representedObject = key; it.state = layout == key ? .on : .off
            m.addItem(it)
        }
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "Выйти из Радара", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        return m
    }
    @objc func openCompare() {
        let p = Process(); p.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? "/Applications/Radar.app/Contents/MacOS/Radar"); p.arguments = ["--compare-dock"]
        try? p.run()
    }
    @objc func switchLayout(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        UserDefaults.standard.set(key, forKey: "layout")
        model.expanded = false; closing = false
        panel.level = top ? .popUpMenu : .statusBar
        host.rootView = makeView()
        container.menu = makeMenu()
        relayout()
    }
    @objc func toggleAutostart() {
        if autostart { try? FileManager.default.removeItem(at: agentURL) }
        else {
            let exe = Bundle.main.executablePath ?? "/Applications/Radar.app/Contents/MacOS/Radar"
            let plist: [String: Any] = ["Label": "com.emil.radar", "ProgramArguments": [exe], "RunAtLoad": true, "ProcessType": "Interactive"]
            try? FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            (plist as NSDictionary).write(to: agentURL, atomically: true)
        }
        container.menu = makeMenu()
    }
}

// MARK: - Проверочные режимы

if CommandLine.arguments.contains("--list-caches") {
    _ = NSApplication.shared
    for u in Cleaner.idleAppCaches() { print(fmtBytes(Cleaner.dirSize(u)), u.lastPathComponent) }
    print("DaVinci:", Cleaner.davinciSize().map(fmtBytes) ?? "нет")
    exit(0)
}
/// --snapshot <папка>: снимки свёрнутого и раскрытого вида (тёмная заливка вместо стекла)
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    let dir = CommandLine.arguments[i + 1]
    let m = Model()
    _ = Sampler.cpu(); usleep(500_000)
    m.cpu = Sampler.cpu(); let mem = Sampler.memory(); m.memUsed = mem.used; m.memTotal = mem.total
    m.disks = Sampler.disks(); m.procs = Sampler.topProcs(3); m.davinciCache = 16_000_000_000; m.appCache = 400_000_000
    MainActor.assumeIsolated {
        @MainActor func shot(_ name: String) {
            let v = NotchView(m: m, barH: 62, plain: true, onToggle: {}, onClean: { _ in })
                .frame(width: max(m.rowW + 52, NotchView.minW) + 40, height: m.expanded ? 62 + m.detailsH + 20 : 82)
                .background(Color(hex: 0x0E0F13)).environment(\.colorScheme, .dark)
            let r = ImageRenderer(content: v); r.scale = 2
            for _ in 0..<3 { _ = r.nsImage }   // несколько проходов, чтобы подтянулись замеры ширины и высоты
            if let img = r.nsImage, let t = img.tiffRepresentation, let b = NSBitmapImageRep(data: t), let png = b.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
            }
        }
        shot("closed.png"); m.expanded = true; shot("open.png")
    }
    print("rowW", m.rowW, "detailsH", m.detailsH)
    exit(0)
}

/// --compare: ряд капсул с разными фонами под строкой меню, чтобы выбрать похожий на строку; щелчок закрывает
struct CompareView: View {
    let barH: CGFloat; let originX: CGFloat
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(Array((201...208).enumerated()), id: \.offset) { n, i in
                VStack(spacing: 2) {
                    Text("\(n + 1)").font(.system(size: 20, weight: .bold))
                    Text("ЦП 24%").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
                .frame(width: 120, height: barH)
                .modifier(Glass(shape: UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22), plain: false, style: i, originX: originX + CGFloat(n) * 134, topFade: (barH / 2).rounded()))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture { NSApp.terminate(nil) }
    }
}
if let i = CommandLine.arguments.firstIndex(of: "--dump-wall"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    if let img = Wall.strip(Wall.presets[105]!, height: 120), let t = img.tiffRepresentation, let b = NSBitmapImageRep(data: t), let png = b.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1])); print("ok", img.size)
    } else { print("нет обоев") }
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--shot-compare"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    MainActor.assumeIsolated {
        let r = ImageRenderer(content: CompareView(barH: 62, originX: 1236).frame(width: 1058, height: 62).background(Color.gray))
        if let img = r.nsImage, let t = img.tiffRepresentation, let b = NSBitmapImageRep(data: t), let png = b.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
        }
    }
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--icons"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    let m = Model()
    _ = Sampler.cpu(); usleep(500_000)
    m.cpu = Sampler.cpu(); let mem = Sampler.memory(); m.memUsed = mem.used; m.memTotal = mem.total; m.disks = Sampler.disks()
    MainActor.assumeIsolated {
        func row(_ st: Int) -> some View {
            HStack(spacing: 20) {
                Text("\(st)").font(.system(size: 22, weight: .heavy)).foregroundStyle(Color(hex: 0xE86E4B)).frame(width: 30)
                Cell(icon: StatIcon(kind: .cpu, color: loadColor(m.cpu, warn: 50, bad: 80), share: m.cpu / 100, style: st), value: "\(Int(m.cpu.rounded()))%", label: "Процессор")
                Cell(icon: StatIcon(kind: .mem, color: loadColor(m.memShare, warn: 75, bad: 90), share: m.memShare / 100, style: st), value: "\(Int(m.memShare.rounded()))%", label: "Память")
                Rectangle().fill(Color.white.opacity(0.18)).frame(width: 0.5, height: 30)
                ForEach(m.disks) { d in Cell(icon: StatIcon(kind: .disk(root: d.isRoot), color: d.color, share: 1 - d.freeShare, style: st), value: fmtBytes(d.free), label: d.name) }
            }
            .padding(.horizontal, 22).frame(height: 58)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(hex: 0x15232F)))
        }
        let v = VStack(alignment: .leading, spacing: 14) { row(1); row(2); row(3); row(4) }
            .fixedSize().padding(20).background(Color(hex: 0x0E0F13)).environment(\.colorScheme, .dark)
        let r = ImageRenderer(content: v); r.scale = 2
        if let img = r.nsImage, let t = img.tiffRepresentation, let b = NSBitmapImageRep(data: t), let png = b.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
        }
    }
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--snapshot-dock"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    let dir = CommandLine.arguments[i + 1]
    let m = Model()
    if ProcessInfo.processInfo.environment["RADAR_DEMO"] != nil {
        // демо-данные для картинок в README
        m.cpu = 18; m.memUsed = 11_800_000_000; m.memTotal = 17_179_869_184
        m.disks = [Disk(id: "/", name: "Мак", free: 120_000_000_000, total: 494_000_000_000, isRoot: true),
                   Disk(id: "/Volumes/Media", name: "Media", free: 40_000_000_000, total: 1_000_000_000_000, isRoot: false),
                   Disk(id: "/Volumes/Archive", name: "Archive", free: 1_400_000_000_000, total: 2_000_000_000_000, isRoot: false)]
        m.procs = [Proc(name: "DaVinci Resolve", cpu: 22, mem: 3_200_000_000), Proc(name: "Safari", cpu: 6, mem: 1_100_000_000), Proc(name: "WindowServer (экран)", cpu: 4, mem: 140_000_000)]
    } else {
        _ = Sampler.cpu(); usleep(500_000)
        m.cpu = Sampler.cpu(); let mem = Sampler.memory(); m.memUsed = mem.used; m.memTotal = mem.total
        m.disks = Sampler.disks(); m.procs = Sampler.topProcs(3)
    }
    m.davinciCache = 16_000_000_000; m.appCache = 400_000_000
    MainActor.assumeIsolated {
        @MainActor func shot(_ name: String) {
            let v = DockView(m: m, plain: true, onToggle: {}, onClean: { _ in })
                .frame(width: DockView.width(m, open: m.expanded), height: m.dockH + (m.expanded ? m.detailsH + 18 : 0)).padding(30)
                .background(Color(hex: 0x0E0F13)).environment(\.colorScheme, .dark)
            let r = ImageRenderer(content: v); r.scale = 2
            for _ in 0..<3 { _ = r.nsImage }
            if let img = r.nsImage, let t = img.tiffRepresentation, let b = NSBitmapImageRep(data: t), let png = b.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
            }
        }
        m.expanded = true; shot("dock_open.png"); shot("dock_open.png"); m.expanded = false; shot("dock_closed.png")
    }
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--snapshot-side"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    let dir = CommandLine.arguments[i + 1]
    let m = Model()
    _ = Sampler.cpu(); usleep(500_000)
    m.cpu = Sampler.cpu(); let mem = Sampler.memory(); m.memUsed = mem.used; m.memTotal = mem.total
    m.disks = Sampler.disks(); m.procs = Sampler.topProcs(3); m.davinciCache = 16_000_000_000; m.appCache = 400_000_000
    MainActor.assumeIsolated {
        @MainActor func shot(_ name: String) {
            let v = SideView(m: m, plain: true, onToggle: {}, onClean: { _ in })
                .frame(width: m.colW + (m.expanded ? SideView.detailsW : 0) + 30, height: max(m.colH, m.expanded ? m.detailsH + 30 : 0) + 30)
                .background(Color(hex: 0x0E0F13)).environment(\.colorScheme, .dark)
            let r = ImageRenderer(content: v); r.scale = 2
            for _ in 0..<3 { _ = r.nsImage }
            if let img = r.nsImage, let t = img.tiffRepresentation, let b = NSBitmapImageRep(data: t), let png = b.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
            }
        }
        m.expanded = true; shot("side_open.png"); shot("side_open.png"); m.expanded = false; shot("side_closed.png")
    }
    print("col", m.colW, m.colH, "details", m.detailsH)
    exit(0)
}
enum CompareDrag { nonisolated(unsafe) static var start: (CGFloat, CGFloat)? }
/// --compare-dock: 6 вариантов стекла внизу, той же высоты и скругления, что Док; щелчок закрывает
if CommandLine.arguments.contains("--compare-dock") {
    let a = NSApplication.shared
    a.setActivationPolicy(.accessory)
    let s = NSScreen.screens[0]
    let reserved = s.visibleFrame.minY - s.frame.minY
    let h = reserved > 20 ? (reserved - 4).rounded() : 54
    let r = (h * 0.27).rounded()
    let cw: CGFloat = 150, gap: CGFloat = 12
    let w = 6 * cw + 5 * gap
    let p = Panel(contentRect: NSRect(x: s.frame.maxX - w - 10, y: s.frame.minY + 4, width: w, height: h), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false; p.level = .statusBar
    p.collectionBehavior = [.canJoinAllSpaces, .stationary]
    let shape = UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: r, bottomTrailingRadius: r, topTrailingRadius: r)
    let v = HStack(spacing: gap) {
        ForEach(Array([329, 333, 337, 341, 345, 349].enumerated()), id: \.offset) { n, st in
            VStack(spacing: 1) {
                Text("\(n + 1)").font(.system(size: 20, weight: .bold))
                Text("затемнение \(st - 300)%\(st == 341 ? " · сейчас" : "")").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            .frame(width: cw, height: h)
            .modifier(Glass(shape: shape, plain: false, style: st))
            .modifier(TopHighlight(shape: shape))
        }
    }
    .modifier(AlwaysActive())
    .contentShape(Rectangle()).onTapGesture { NSApp.terminate(nil) }
    .gesture(DragGesture(minimumDistance: 5).onChanged { _ in
        let mx = NSEvent.mouseLocation.x
        if CompareDrag.start == nil { CompareDrag.start = (mx, p.frame.minX) }
        if let st = CompareDrag.start { var f = p.frame; f.origin.x = (st.1 + mx - st.0).rounded(); p.setFrame(f, display: true) }
    }.onEnded { _ in CompareDrag.start = nil })
    p.contentView = NSHostingView(rootView: v)
    p.orderFrontRegardless()
    a.run()
}
if CommandLine.arguments.contains("--compare") {
    let a = NSApplication.shared
    a.setActivationPolicy(.accessory)
    let s = NSScreen.screens[0]
    let mbh = s.frame.maxY - s.visibleFrame.maxY
    let barH = (mbh * 2).rounded()
    let w: CGFloat = 8 * 120 + 7 * 14
    let p = Panel(contentRect: NSRect(x: (s.frame.midX - w / 2).rounded(), y: s.frame.maxY - barH, width: w, height: barH), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false; p.level = .popUpMenu
    p.collectionBehavior = [.canJoinAllSpaces, .stationary]
    p.contentView = NSHostingView(rootView: CompareView(barH: barH, originX: p.frame.minX - s.frame.minX))
    p.orderFrontRegardless()
    a.run()
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
