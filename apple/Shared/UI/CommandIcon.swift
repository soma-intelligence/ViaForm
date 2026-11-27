import SwiftUI

/// A command's icon: the rendered satin-black one from Resources/ToolIcons when there is one
/// (scripts/icons), else an SF Symbol. Used by the ribbons, the marking menu, the toolbox and the
/// command form, so every place shows the same picture for the same command.
struct CommandIcon: View {
    private let art: String?
    private let symbol: String
    var size: CGFloat = 20
    @Environment(\.colorScheme) private var scheme

    /// A registry command (its `icon` name and id).
    init(icon: String, id: String, size: CGFloat = 20) {
        let tool = Tool.allCases.first { $0.commandID == id }
        self.art = ToolIcons.has(icon) ? icon : tool.flatMap(ToolIcons.art)
        self.symbol = CommandSymbol.of(icon, id: id)
        self.size = size
    }

    /// One of the app's tools.
    init(tool: Tool, size: CGFloat = 20) {
        self.art = ToolIcons.art(for: tool)
        self.symbol = tool.symbol
        self.size = size
    }

    /// Any action: a rendered icon name when it has one, else the SF Symbol.
    init(art: String?, symbol: String, size: CGFloat = 20) {
        self.art = art.flatMap { ToolIcons.has($0) ? $0 : nil }
        self.symbol = symbol
        self.size = size
    }

    var body: some View {
        if let art, let image = ToolIcons.image(art) {
            image
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size + 8, height: size + 8)
                // The satin-black renders vanish on a dark ribbon: a soft light rim keeps their outline readable.
                .shadow(color: scheme == .dark ? .white.opacity(0.32) : .black.opacity(0.25),
                        radius: scheme == .dark ? 1.2 : 0.5, y: scheme == .dark ? 0 : 0.5)
                .shadow(color: scheme == .dark ? .white.opacity(0.12) : .clear, radius: 4)
        } else {
            Image(systemName: symbol).font(VFFont.icon(size))
        }
    }
}

enum ToolIcons {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Image?] = [:]

    /// The rendered icon for a tool, when one exists.
    static func art(for tool: Tool) -> String? {
        switch tool {
        case .select: "select"
        case .point: "point_vertex"
        case .sketch: "sketch"
        case .extrude: "extrude"
        case .revolve: "revolve"
        case .pressPull: "presspull"
        case .fillet: "fillet"
        case .chamfer: "chamfer"
        case .shell: "shell"
        case .box: "box"
        case .cylinder: "cylinder"
        case .union: "combine"
        case .delete: "delete"
        case .measure: "measure"
        default: nil
        }
    }

    static func has(_ name: String) -> Bool { image(name) != nil }

    static func image(_ name: String) -> Image? {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[name] { return hit }
        var image: Image?
        if let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "ToolIcons") {
            #if os(macOS)
            image = NSImage(contentsOf: url).map { Image(nsImage: $0) }
            #else
            image = UIImage(contentsOfFile: url.path).map { Image(uiImage: $0) }
            #endif
        }
        cache[name] = image
        return image
    }
}
