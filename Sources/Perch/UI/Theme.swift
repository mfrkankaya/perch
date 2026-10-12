import AppKit
import SwiftUI

// MARK: - "Dusk" design system
// Taken from the app icon: a night-indigo sky, a warm amber bird, a teal horizon.

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

enum Dusk {
    static let night = Color(hex: 0x0F0E24)
    static let indigo = Color(hex: 0x1B1942)
    static let horizon = Color(hex: 0x0B2834)

    static let surface = Color.white.opacity(0.045)
    static let surfaceHi = Color.white.opacity(0.085)
    static let surfaceTop = Color.white.opacity(0.13)
    static let stroke = Color.white.opacity(0.08)
    static let strokeHi = Color.white.opacity(0.16)

    static let text = Color(hex: 0xF6F2E9)
    static let text2 = Color(hex: 0xADABCF)
    static let text3 = Color(hex: 0x737199)
    static let ink = Color(hex: 0x1A1433)          // text on amber

    static let amber = Color(hex: 0xFFC54D)
    static let orange = Color(hex: 0xFF7A3D)
    static let teal = Color(hex: 0x3FD9C4)
    static let violet = Color(hex: 0xA08FFF)
    static let coral = Color(hex: 0xFF6B7A)
    static let green = Color(hex: 0x5BE3A6)
    static let sky = Color(hex: 0x6BA8FF)

    static let accent = LinearGradient(colors: [amber, orange], startPoint: .topLeading, endPoint: .bottomTrailing)
    static func gradient(_ a: Color, _ b: Color) -> LinearGradient {
        LinearGradient(colors: [a, b], startPoint: .leading, endPoint: .trailing)
    }

    static func title(_ size: CGFloat = 26) -> Font { .system(size: size, weight: .bold, design: .rounded) }
    static func heading(_ size: CGFloat = 15) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
    static func number(_ size: CGFloat = 15, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
    static let body = Font.system(size: 13)
    static let caption = Font.system(size: 11.5)
    static let micro = Font.system(size: 10.5, weight: .semibold, design: .rounded)

    static let darkAppearance = NSAppearance(named: .darkAqua)
}

// MARK: - Background

struct DuskBackground: View {
    var stars = true

    var body: some View {
        ZStack {
            LinearGradient(colors: [Dusk.indigo, Dusk.night, Dusk.horizon],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Dusk.amber.opacity(0.13), .clear], center: .topTrailing, startRadius: 0, endRadius: 420)
            RadialGradient(colors: [Dusk.teal.opacity(0.08), .clear], center: .bottomLeading, startRadius: 0, endRadius: 380)
            if stars {
                // Drawn once per resize – no animation, no cost at rest.
                Canvas { ctx, size in
                    var rng = SeededRandom(seed: 7)
                    for _ in 0..<Int(size.width * size.height / 9000) {
                        let p = CGPoint(x: rng.next() * size.width, y: rng.next() * size.height * 0.7)
                        let r = rng.next() * 1.1 + 0.3
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x, y: p.y, width: r, height: r)),
                                 with: .color(.white.opacity(0.08 + rng.next() * 0.18)))
                    }
                }
            }
        }
        .ignoresSafeArea()
    }
}

struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat((state >> 33) % 10_000) / 10_000
    }
}

// MARK: - Surfaces

struct DuskCard<Content: View>: View {
    var padding: CGFloat = 16
    var radius: CGFloat = 18
    var tint: Color? = nil
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(tint.map { $0.opacity(0.10) } ?? Dusk.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(tint.map { $0.opacity(0.28) } ?? Dusk.stroke)
            )
    }
}

extension View {
    func card() -> some View { DuskCard(padding: 12, radius: 14) { self } }

    func duskText(_ level: Int = 1) -> some View {
        foregroundStyle(level == 1 ? Dusk.text : (level == 2 ? Dusk.text2 : Dusk.text3))
    }
}

struct IconBadge: View {
    let symbol: String
    var tint: Color = Dusk.amber
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.47, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.32, style: .continuous).fill(tint.opacity(0.16)))
            .overlay(RoundedRectangle(cornerRadius: size * 0.32, style: .continuous).strokeBorder(tint.opacity(0.22)))
    }
}

struct Tag: View {
    let text: String
    var tint: Color = Dusk.text2
    var body: some View {
        Text(text).font(Dusk.micro)
            .padding(.horizontal, 7).padding(.vertical, 2.5)
            .foregroundStyle(tint)
            .background(Capsule().fill(tint.opacity(0.14)))
    }
}

// MARK: - Buttons

struct DuskButton: ButtonStyle {
    enum Kind { case primary, secondary, danger, ghost }
    var kind: Kind = .secondary
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        Inner(configuration: configuration, kind: kind, large: large)
    }

    private struct Inner: View {
        let configuration: Configuration
        let kind: Kind
        let large: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false

        var body: some View {
            configuration.label
                .font(.system(size: large ? 13.5 : 12.5, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .padding(.horizontal, kind == .ghost ? 8 : (large ? 18 : 13))
                .padding(.vertical, large ? 9 : 6)
                .foregroundStyle(foreground)
                .background(background)
                .overlay(Capsule().strokeBorder(border))
                .contentShape(Capsule())
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .brightness(hover && enabled ? 0.06 : 0)
                .opacity(enabled ? 1 : 0.4)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .onHover { hover = $0 }
        }

        private var foreground: Color {
            switch kind {
            case .primary: Dusk.ink
            case .danger: Dusk.coral
            case .secondary, .ghost: Dusk.text
            }
        }

        @ViewBuilder private var background: some View {
            switch kind {
            case .primary:
                Capsule().fill(Dusk.accent)
                    .shadow(color: Dusk.orange.opacity(enabled ? 0.35 : 0), radius: 10, y: 3)
            case .danger: Capsule().fill(Dusk.coral.opacity(hover ? 0.24 : 0.16))
            case .secondary: Capsule().fill(hover ? Dusk.surfaceTop : Dusk.surfaceHi)
            case .ghost: Capsule().fill(hover ? Dusk.surfaceHi : .clear)
            }
        }

        private var border: Color {
            switch kind {
            case .primary: .white.opacity(0.25)
            case .danger: Dusk.coral.opacity(0.3)
            case .secondary: Dusk.stroke
            case .ghost: .clear
            }
        }
    }
}

struct IconButton: View {
    let symbol: String
    var help: String = ""
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(hover ? Dusk.text : Dusk.text2)
                .frame(width: 28, height: 28)
                .background(Circle().fill(hover ? Dusk.surfaceTop : Dusk.surfaceHi))
                .overlay(Circle().strokeBorder(Dusk.stroke))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

// MARK: - Controls

/// Tri-state checkbox: true / false / nil (mixed).
struct DuskCheck: View {
    let state: Bool?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                    .fill(state == false ? AnyShapeStyle(Color.clear) : AnyShapeStyle(Dusk.accent))
                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                    .strokeBorder(state == false ? Dusk.text3 : .white.opacity(0.3), lineWidth: 1.4)
                if state != false {
                    Image(systemName: state == nil ? "minus" : "checkmark")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(Dusk.ink)
                }
            }
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Pure-SwiftUI switch: also handles the click that activates an inactive panel.
struct PillSwitch: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let on = configuration.isOn
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule()
                .fill(on ? AnyShapeStyle(Dusk.accent) : AnyShapeStyle(Color.white.opacity(0.12)))
                .overlay(Capsule().strokeBorder(on ? .white.opacity(0.25) : Dusk.stroke))
            Circle().fill(on ? Dusk.ink : Dusk.text2)
                .padding(3)
        }
        .frame(width: 38, height: 22)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: on)
        .opacity(isEnabled ? 1 : 0.45)
        .contentShape(Capsule())
        .onTapGesture { configuration.isOn.toggle() }
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(on ? L("Açık") : L("Kapalı"))
    }
}

struct DuskSegmented<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]
    var compact = false
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, title in
                let on = value == selection
                Text(title)
                    .font(.system(size: compact ? 11.5 : 12.5, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .foregroundStyle(on ? Dusk.ink : Dusk.text2)
                    .padding(.horizontal, compact ? 9 : 13).padding(.vertical, compact ? 4 : 6)
                    .frame(maxWidth: compact ? .infinity : nil)
                    .background {
                        if on {
                            Capsule().fill(Dusk.accent).matchedGeometryEffect(id: "pill", in: ns)
                        }
                    }
                    .contentShape(Capsule())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { selection = value }
                    }
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.black.opacity(0.22)))
        .overlay(Capsule().strokeBorder(Dusk.stroke))
    }
}

struct DuskBar: View {
    let value: Double
    var fill: AnyShapeStyle = AnyShapeStyle(Dusk.accent)
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.07))
                Capsule().fill(fill)
                    .frame(width: max(height, g.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: height)
    }
}

struct DuskSearchField: View {
    @Binding var text: String
    var placeholder: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(Dusk.text3)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .foregroundStyle(Dusk.text)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Dusk.text3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 7)
        .background(Capsule().fill(Color.black.opacity(0.22)))
        .overlay(Capsule().strokeBorder(Dusk.stroke))
    }
}

/// Small spinner in brand colours; animates only while on screen.
struct DuskSpinner: View {
    var size: CGFloat = 26
    @State private var spin = false

    var body: some View {
        Circle()
            .trim(from: 0.08, to: 0.78)
            .stroke(AngularGradient(colors: [Dusk.amber.opacity(0), Dusk.amber, Dusk.orange], center: .center),
                    style: StrokeStyle(lineWidth: size * 0.12, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .onAppear { withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true } }
    }
}

struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Dusk.title()).foregroundStyle(Dusk.text)
                Text(subtitle).font(Dusk.body).foregroundStyle(Dusk.text2)
            }
            Spacer(minLength: 12)
            trailing
        }
    }
}

struct EmptyState: View {
    let symbol: String
    let text: String
    var body: some View {
        VStack(spacing: 12) {
            IconBadge(symbol: symbol, tint: Dusk.text3, size: 54)
            Text(text).font(Dusk.body).foregroundStyle(Dusk.text2).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Row background with hover + selection, used by every list.
struct RowChrome: ViewModifier {
    var selected = false
    @State private var hover = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(selected ? Dusk.amber.opacity(0.12) : (hover ? Dusk.surfaceHi : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(selected ? Dusk.amber.opacity(0.35) : .clear)
            )
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}

extension View {
    func rowChrome(selected: Bool = false) -> some View { modifier(RowChrome(selected: selected)) }
}

/// Floating bottom bar for bulk actions.
struct ActionBar<Leading: View, Actions: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 10) {
            leading
            Spacer(minLength: 8)
            actions
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Dusk.indigo.opacity(0.92)))
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Dusk.strokeHi))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }
}

struct AppIconView: View {
    let path: String
    let size: CGFloat
    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
            .resizable()
            .frame(width: size, height: size)
    }
}

struct FullDiskAccessBanner: View {
    var body: some View {
        DuskCard(padding: 12, radius: 14, tint: Dusk.amber) {
            HStack(spacing: 12) {
                IconBadge(symbol: "lock.shield.fill", tint: Dusk.amber, size: 28)
                Text(L("Fotoğraflar, Mail ve uygulama kapsayıcıları gibi korumalı klasörler atlanıyor. Hepsini görmek için Perch'e Tam Disk Erişimi ver, sonra yeniden tara."))
                    .font(Dusk.caption).foregroundStyle(Dusk.text2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(L("Ayarları aç")) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                }
                .buttonStyle(DuskButton(kind: .secondary))
            }
        }
    }
}

/// Idle "nothing scanned yet" screen with one big start button.
struct StartScanView<Extra: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    let chips: [(String, String)]   // (symbol, text)
    let buttonTitle: String
    let action: () -> Void
    @ViewBuilder var extra: Extra
    @State private var hover = false

    var body: some View {
        VStack(spacing: 18) {
            Button(action: action) {
                ZStack {
                    Circle().fill(RadialGradient(colors: [tint.opacity(hover ? 0.32 : 0.22), .clear],
                                                 center: .center, startRadius: 10, endRadius: 120))
                        .frame(width: 196, height: 196)
                    Circle().strokeBorder(tint.opacity(0.18), lineWidth: 1).frame(width: 156, height: 156)
                    Circle().strokeBorder(tint.opacity(0.32), lineWidth: 1).frame(width: 126, height: 126)
                    Circle().fill(Dusk.accent)
                        .frame(width: 96, height: 96)
                        .shadow(color: Dusk.orange.opacity(hover ? 0.6 : 0.4), radius: hover ? 26 : 18, y: 6)
                        .overlay(Circle().strokeBorder(.white.opacity(0.3)))
                    Image(systemName: symbol)
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(Dusk.ink)
                }
                .scaleEffect(hover ? 1.04 : 1)
                .animation(.spring(response: 0.35, dampingFraction: 0.7), value: hover)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }

            VStack(spacing: 8) {
                Text(title).font(Dusk.title(24))
                Text(subtitle).font(Dusk.body).foregroundStyle(Dusk.text2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460)
            }

            if !chips.isEmpty {
                FlowChips(chips: chips, tint: tint)
            }

            VStack(spacing: 10) {
                Button(action: action) { Label(buttonTitle, systemImage: "play.fill") }
                    .buttonStyle(DuskButton(kind: .primary, large: true))
                extra
            }
            Label(L("Sen onaylamadan hiçbir şey silinmez"), systemImage: "lock.fill")
                .font(Dusk.caption).foregroundStyle(Dusk.text3)
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FlowChips: View {
    let chips: [(String, String)]
    let tint: Color

    var body: some View {
        // Wraps to as many centred rows as the width allows; never forces the window wider.
        FlowLayout(spacing: 8) {
            ForEach(chips, id: \.1) { symbol, text in
                HStack(spacing: 6) {
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                    Text(text).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(Dusk.text2)
                        .lineLimit(1)
                }
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(Capsule().fill(Dusk.surface))
                .overlay(Capsule().strokeBorder(Dusk.stroke))
            }
        }
        .frame(maxWidth: 640)
    }
}

/// Minimal centred flow layout.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    private func rows(_ subviews: Subviews, width: CGFloat) -> [[(Int, CGSize)]] {
        var rows: [[(Int, CGSize)]] = [[]]
        var x: CGFloat = 0
        for (i, sv) in subviews.enumerated() {
            let size = sv.sizeThatFits(.unspecified)
            let w = min(size.width, width)
            if x > 0 && x + w > width { rows.append([]); x = 0 }
            rows[rows.count - 1].append((i, CGSize(width: w, height: size.height)))
            x += w + spacing
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rs = rows(subviews, width: width)
        let height = rs.reduce(0) { $0 + ($1.map(\.1.height).max() ?? 0) } + spacing * CGFloat(max(rs.count - 1, 0))
        let used = rs.map { r in r.reduce(0) { $0 + $1.1.width } + spacing * CGFloat(max(r.count - 1, 0)) }.max() ?? 0
        return CGSize(width: proposal.width ?? used, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for r in rows(subviews, width: bounds.width) {
            let rowW = r.reduce(0) { $0 + $1.1.width } + spacing * CGFloat(max(r.count - 1, 0))
            let rowH = r.map(\.1.height).max() ?? 0
            var x = bounds.minX + (bounds.width - rowW) / 2
            for (i, size) in r {
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += rowH + spacing
        }
    }
}
