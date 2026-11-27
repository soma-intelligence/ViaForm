import SwiftUI

// MARK: - Glass surface

/// One glass surface for every floating panel: 18 pt radius, 1 px white hairline, brighter top rim,
/// soft shadow. Live it is `.glassEffect` on macOS 26 and `.ultraThinMaterial` on 14 and 15.
struct GlassSurface<S: InsettableShape>: ViewModifier {
    var shape: S
    var tint: Double = 0.78
    var shadow = true
    @Environment(\.staticRender) private var staticRender
    @Environment(\.backdrop) private var backdrop
    @Environment(\.windowSize) private var windowSize

    func body(content: Content) -> some View {
        content
            .background { fill }
            .overlay { rim.allowsHitTesting(false) }
            .compositingGroup()
            .shadow(color: .black.opacity(shadow ? 0.35 : 0), radius: 20, y: 8)
    }

    @ViewBuilder private var fill: some View {
        if staticRender, let b = backdrop {
            // Frosted glass for ImageRenderer: the plate behind the panel, blurred, then tinted.
            GeometryReader { g in
                let f = g.frame(in: .global), pf = b.frame(in: windowSize)
                Asset.plate(b.name).resizable().frame(width: pf.width, height: pf.height)
                    .offset(x: pf.minX - f.minX, y: pf.minY - f.minY)
                    .blur(radius: 22)
            }
            .clipShape(shape)
            .overlay(shape.fill(Color(hex: 0x1A1C22).opacity(tint * 0.74)))
            .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.09), .white.opacity(0.02)],
                                               startPoint: .top, endPoint: .bottom)))
        } else if staticRender {
            shape.fill(Color(hex: 0x1C1E24).opacity(tint))
                .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.075), .white.opacity(0.02)],
                                                   startPoint: .top, endPoint: .bottom)))
        } else if #available(macOS 26, *) {
            Color.clear.glassEffect(.regular.tint(Color(hex: 0x1C1E24).opacity(0.35)), in: shape)
        } else {
            shape.fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                .overlay(shape.fill(Color(hex: 0x1C1E24).opacity(0.45)))
        }
    }

    private var rim: some View {
        shape.strokeBorder(LinearGradient(stops: [
            .init(color: .white.opacity(0.30), location: 0),
            .init(color: .white.opacity(0.12), location: 0.18),
            .init(color: .white.opacity(0.10), location: 0.8),
            .init(color: .white.opacity(0.06), location: 1),
        ], startPoint: .top, endPoint: .bottom), lineWidth: 1)
    }
}

extension View {
    func glass(_ radius: CGFloat = Tok.radius, tint: Double = 0.78, shadow: Bool = true) -> some View {
        modifier(GlassSurface(shape: RoundedRectangle(cornerRadius: radius, style: .continuous), tint: tint, shadow: shadow))
    }

    func glassCapsule(tint: Double = 0.78) -> some View {
        modifier(GlassSurface(shape: Capsule(style: .continuous), tint: tint))
    }

    func glassCircle(tint: Double = 0.78) -> some View {
        modifier(GlassSurface(shape: Circle(), tint: tint))
    }
}

// MARK: - Panel building blocks

struct PanelHeader: View {
    var icon: String? = nil
    var tool: String? = nil
    var title: String
    var trailing: String? = nil
    var close = false

    var body: some View {
        HStack(spacing: 10) {
            if let tool { Asset.tool(tool).resizable().frame(width: 22, height: 22) }
            if let icon { Image(systemName: icon).font(.system(size: 15, weight: .medium)).foregroundStyle(Tok.primary) }
            Text(title).font(Tok.title).foregroundStyle(Tok.primary).lineLimit(1)
            if let trailing { Text(trailing).font(Tok.mono(12)).foregroundStyle(Tok.secondary) }
            Spacer(minLength: 4)
            if close {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Tok.secondary)
                    .frame(width: 22, height: 22).background(Circle().fill(.white.opacity(0.06)))
            }
        }
        .padding(.horizontal, Tok.pad).frame(height: 44)
    }
}

struct Hairline: View {
    var inset: CGFloat = Tok.pad
    var body: some View { Rectangle().fill(Tok.hairline).frame(height: 1).padding(.horizontal, inset) }
}

/// Inspector key/value row: key 13 regular secondary, value SF Mono for numbers, chevron for pickers.
struct KVRow: View {
    var key: String
    var value: String
    var mono = true
    var picker = false
    var dot: Color? = nil
    var check = false

    var body: some View {
        HStack(spacing: 8) {
            Text(key).font(Tok.body()).foregroundStyle(Tok.secondary)
            Spacer(minLength: 8)
            if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
            Text(value).font(mono ? Tok.mono(13) : Tok.body()).foregroundStyle(Tok.primary).lineLimit(1)
            if check { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Color(hex: 0x34C759)) }
            if picker {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Tok.secondary)
            }
        }
        .padding(.horizontal, Tok.pad).frame(height: 30)
    }
}

struct PrimaryButton: View {
    var title: String
    var symbol: String? = nil
    var height: CGFloat = 32
    @Environment(\.accent) private var accent
    @Environment(\.onAccent) private var onAccent

    var body: some View {
        HStack(spacing: 7) {
            if let symbol { Image(systemName: symbol).font(.system(size: 13, weight: .semibold)) }
            Text(title).font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(onAccent)
        .frame(maxWidth: .infinity).frame(height: height)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(accent))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 1))
        .shadow(color: accent.opacity(0.35), radius: 8, y: 2)
    }
}

struct SecondaryButton: View {
    var title: String
    var height: CGFloat = 32
    var body: some View {
        Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Tok.primary)
            .frame(maxWidth: .infinity).frame(height: height)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }
}

/// Small glyph button inside a glass toolbar.
struct ChromeButton: View {
    var symbol: String
    var size: CGFloat = 30
    var active = false
    var body: some View {
        Image(systemName: symbol).font(.system(size: 14, weight: .regular)).foregroundStyle(Tok.primary)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(active ? 0.12 : 0.0)))
    }
}

// MARK: - Viewport background

struct ViewportBackground: View {
    var plate: PlateLayout?
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Tok.viewTop, Tok.viewBottom], startPoint: .top, endPoint: .bottom)
                GroundGrid().opacity(0.6)
                if let plate {
                    let f = plate.frame(in: geo.size)
                    Asset.plate(plate.name).resizable()
                        .frame(width: f.width, height: f.height)
                        .mask {
                            if plate.feather {
                                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.1),
                                                       .init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                                               startPoint: .leading, endPoint: .trailing)
                                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08),
                                                                 .init(color: .black, location: 0.92), .init(color: .clear, location: 1)],
                                                         startPoint: .top, endPoint: .bottom))
                            } else { Color.black }
                        }
                        .offset(x: f.minX, y: f.minY)
                }
            }
        }
        .clipped()
    }
}

/// Faint perspective ground grid, drawn when no plate covers the viewport (the PCB canvas).
struct GroundGrid: View {
    var body: some View {
        Canvas { ctx, size in
            let horizon = size.height * 0.42
            let vp = CGPoint(x: size.width / 2, y: horizon)
            var p = Path()
            for i in -24...24 {
                let x = size.width / 2 + CGFloat(i) * size.width / 12
                p.move(to: vp); p.addLine(to: CGPoint(x: x * 3 - size.width, y: size.height * 1.6))
            }
            for k in 1...16 {
                let t = pow(CGFloat(k) / 16, 2.2)
                let y = horizon + (size.height - horizon) * t
                p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
            }
            ctx.clip(to: Path(CGRect(x: 0, y: horizon, width: size.width, height: size.height)))
            ctx.stroke(p, with: .linearGradient(Gradient(colors: [.white.opacity(0.0), .white.opacity(0.07)]),
                                                 startPoint: CGPoint(x: 0, y: horizon), endPoint: CGPoint(x: 0, y: size.height)),
                       lineWidth: 1)
        }
    }
}
