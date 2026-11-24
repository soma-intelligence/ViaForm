import SceneKit
import SwiftUI
import simd
#if os(macOS)
import AppKit
typealias GenerateColor = NSColor
typealias GenerateImage = NSImage
#else
import UIKit
typealias GenerateColor = UIColor
typealias GenerateImage = UIImage
#endif

// MARK: Stress colours

/// The stress heat map. Viridis by default (FRONTEND-SPEC 7.8: perceptually even and readable
/// with colour blindness); a red-blue diverging scale on request. Data colours, not UI tokens:
/// they paint the 3D preview, and the legend mirrors them.
enum StressColors {
    enum Scale: String, CaseIterable, Identifiable, Sendable {
        case viridis, redBlue
        var id: String { rawValue }
        var title: String {
            switch self {
            case .viridis: String(localized: "Viridis")
            case .redBlue: String(localized: "Blue to red")
            }
        }
        var stops: [SIMD3<Float>] {
            switch self {
            case .viridis:
                [SIMD3(0.267, 0.005, 0.329), SIMD3(0.231, 0.322, 0.545), SIMD3(0.129, 0.569, 0.549),
                 SIMD3(0.369, 0.788, 0.384), SIMD3(0.992, 0.906, 0.145)]
            case .redBlue:
                [SIMD3(0.129, 0.400, 0.675), SIMD3(0.404, 0.663, 0.812), SIMD3(0.969, 0.969, 0.969),
                 SIMD3(0.937, 0.541, 0.384), SIMD3(0.698, 0.094, 0.169)]
            }
        }
    }

    private static let storageKey = "generate.stressScale"

    /// The scale the next previews are coloured with (read off the main actor too).
    static var current: Scale {
        get { UserDefaults.standard.string(forKey: storageKey).flatMap(Scale.init(rawValue:)) ?? .viridis }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: storageKey) }
    }

    /// `t` in 0...1 along the scale; above 1 stays at the top colour.
    static func rgb(_ t: Float, scale: Scale = current) -> SIMD3<Float> {
        let stops = scale.stops
        let x = min(max(t.isFinite ? t : 0, 0), 1) * Float(stops.count - 1)
        let i = min(Int(x), stops.count - 2)
        return simd_mix(stops[i], stops[i + 1], SIMD3(repeating: x - Float(i)))
    }

    /// P2-26: legend bands that read without colour. Off the colour, `--differentiate-without-color`
    /// forces them for screenshots and checks.
    static let forceDifferentiate = ProcessInfo.processInfo.arguments.contains("--differentiate-without-color")

    /// The legend's worded bands, as fractions of the allowable: low up to 80 % of the limit,
    /// at the limit from there to the limit, over the limit beyond it.
    struct Band: Identifiable, Equatable {
        enum Kind { case low, atLimit, over }
        var kind: Kind
        var from: Double
        var to: Double
        var id: Kind { kind }
        var title: String {
            switch kind {
            case .low: String(localized: "Low")
            case .atLimit: String(localized: "At limit")
            case .over: String(localized: "Over limit")
            }
        }
    }

    static let nearLimit = 0.8

    static func bands(limit: Double, allowable: Double) -> [Band] {
        let a = max(allowable, 1e-9)
        let l = min(max(limit / a, 0), 1)
        let near = l * nearLimit
        return [Band(kind: .low, from: 0, to: near), Band(kind: .atLimit, from: near, to: l), Band(kind: .over, from: l, to: 1)]
            .filter { $0.to > $0.from }
    }

    static func gradient(_ scale: Scale = current) -> Gradient {
        Gradient(colors: scale.stops.map { Color(scene: SIMD3(Double($0.x), Double($0.y), Double($0.z))) })
    }
}

extension Color {
    /// A colour the 3D preview paints (region kinds, stress scale), so a legend matches the scene.
    init(scene rgb: SIMD3<Double>) {
        self.init(cgColor: CGColor(srgbRed: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1))
    }
}

// MARK: Preview geometry

/// A candidate's surface ready for the GPU: packed positions, normals and colours, built off
/// the main actor with the outcome. When the engine sent no surface, the solid voxels' outer
/// faces stand in for it.
struct PreviewMesh: Sendable {
    var positions = Data()
    var normals = Data()
    /// RGBA floats per vertex.
    var colors = Data()
    var indices = Data()
    var vertexCount = 0
    var triangleCount = 0
    var min = SIMD3<Float>(repeating: 0)
    var max = SIMD3<Float>(repeating: 0)
    /// Worst vertex stress, MPa (0 when the engine sent none).
    var peakStress: Float = 0
    var coloredByStress = false
    /// Connected patches of the surface over the study's stress limit (P2-26: the legend says
    /// it in words), and their share of the vertices.
    var overLimitRegions = 0
    var overLimitShare: Float = 0
    /// The surface is the voxels' faces (the engine sent no mesh).
    var voxels = false

    var isEmpty: Bool { triangleCount == 0 }

    static func make(_ c: StudyCandidate, study: Study) -> PreviewMesh {
        let base = SimColor(hex: study.material.color)
        var rgb = SIMD3<Float>(0.72, 0.75, 0.78)
        #if os(macOS)
        if let s = base.usingColorSpace(.sRGB) { rgb = SIMD3(Float(s.redComponent), Float(s.greenComponent), Float(s.blueComponent)) }
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if base.getRed(&r, green: &g, blue: &b, alpha: &a) { rgb = SIMD3(Float(r), Float(g), Float(b)) }
        #endif
        if c.mesh.triangleCount > 0, c.mesh.vertexCount > 0 {
            return surface(c.mesh, allowable: Float(study.material.allowable), limit: Float(study.stressLimit), plain: rgb)
        }
        return voxelFaces(c.grid, c.density, plain: rgb)
    }

    /// A live preview's coarse surface, in the material's colour.
    static func live(_ m: StudyMesh, study: Study) -> PreviewMesh {
        var rgb = SIMD3<Float>(0.72, 0.75, 0.78)
        let base = SimColor(hex: study.material.color)
        #if os(macOS)
        if let s = base.usingColorSpace(.sRGB) { rgb = SIMD3(Float(s.redComponent), Float(s.greenComponent), Float(s.blueComponent)) }
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if base.getRed(&r, green: &g, blue: &b, alpha: &a) { rgb = SIMD3(Float(r), Float(g), Float(b)) }
        #endif
        var plain = m
        plain.stress = []
        return surface(plain, allowable: 0, limit: 0, plain: rgb)
    }

    /// The engine's surface: area-weighted vertex normals, colours from the vertex stress.
    private static func surface(_ m: StudyMesh, allowable: Float, limit: Float, plain: SIMD3<Float>) -> PreviewMesh {
        let n = m.vertexCount
        var out = PreviewMesh()
        // Keep only triangles whose corners exist.
        var tris = [UInt32]()
        tris.reserveCapacity(m.indices.count)
        m.indices.withUnsafeBufferPointer { idx in
            for t in 0..<(idx.count / 3) {
                let a = idx[3 * t], b = idx[3 * t + 1], c = idx[3 * t + 2]
                if Int(a) < n, Int(b) < n, Int(c) < n { tris.append(a); tris.append(b); tris.append(c) }
            }
        }
        var normals = [SIMD3<Float>](repeating: .zero, count: n)
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        m.positions.withUnsafeBufferPointer { p in
            func at(_ i: UInt32) -> SIMD3<Float> { let k = Int(i) * 3; return SIMD3(p[k], p[k + 1], p[k + 2]) }
            for t in stride(from: 0, to: tris.count, by: 3) {
                let a = at(tris[t]), b = at(tris[t + 1]), c = at(tris[t + 2])
                let f = simd_cross(b - a, c - a)
                normals[Int(tris[t])] += f
                normals[Int(tris[t + 1])] += f
                normals[Int(tris[t + 2])] += f
            }
            for i in 0..<n {
                let v = SIMD3(p[3 * i], p[3 * i + 1], p[3 * i + 2])
                if v.x.isFinite, v.y.isFinite, v.z.isFinite { lo = simd_min(lo, v); hi = simd_max(hi, v) }
            }
        }
        var packedNormals = [Float](repeating: 0, count: 3 * n)
        for i in 0..<n {
            let l = simd_length(normals[i])
            let u = l > 0 ? normals[i] / l : SIMD3(0, 0, 1)
            packedNormals[3 * i] = u.x
            packedNormals[3 * i + 1] = u.y
            packedNormals[3 * i + 2] = u.z
        }
        let stressed = m.stress.count == n && allowable > 0
        var colors = [Float](repeating: 1, count: 4 * n)
        var peak: Float = 0
        for i in 0..<n {
            let c: SIMD3<Float>
            if stressed {
                let s = m.stress[i]
                if s.isFinite { peak = Swift.max(peak, s) }
                c = StressColors.rgb(s / allowable)
            } else {
                c = plain
            }
            colors[4 * i] = c.x
            colors[4 * i + 1] = c.y
            colors[4 * i + 2] = c.z
        }
        out.positions = m.positions.withUnsafeBufferPointer { Data(buffer: $0) }
        out.normals = packedNormals.withUnsafeBufferPointer { Data(buffer: $0) }
        out.colors = colors.withUnsafeBufferPointer { Data(buffer: $0) }
        out.indices = tris.withUnsafeBufferPointer { Data(buffer: $0) }
        out.vertexCount = n
        out.triangleCount = tris.count / 3
        out.min = lo.x <= hi.x ? lo : .zero
        out.max = lo.x <= hi.x ? hi : .zero
        out.peakStress = peak
        out.coloredByStress = stressed
        if stressed, limit > 0 {
            let (regions, over) = overLimit(stress: m.stress, triangles: tris, limit: limit)
            out.overLimitRegions = regions
            out.overLimitShare = n > 0 ? Float(over) / Float(n) : 0
        }
        return out
    }

    /// Vertices over `limit` joined by the triangle edges between them: the number of
    /// connected patches, and how many vertices they hold.
    static func overLimit(stress: [Float], triangles: [UInt32], limit: Float) -> (regions: Int, vertices: Int) {
        let n = stress.count
        var parent = Array(0..<n)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        func over(_ i: Int) -> Bool { stress[i].isFinite && stress[i] > limit }
        func join(_ a: Int, _ b: Int) {
            guard a < n, b < n, over(a), over(b) else { return }
            let ra = root(a), rb = root(b)
            if ra != rb { parent[ra] = rb }
        }
        for t in stride(from: 0, to: triangles.count - 2, by: 3) {
            let a = Int(triangles[t]), b = Int(triangles[t + 1]), c = Int(triangles[t + 2])
            join(a, b); join(b, c); join(c, a)
        }
        var roots = Set<Int>(), count = 0
        for i in 0..<n where over(i) {
            count += 1
            roots.insert(root(i))
        }
        return (roots.count, count)
    }

    /// The outer faces of the voxels at density 0.5 and over, flat shaded.
    private static func voxelFaces(_ g: StudyGrid, _ density: [Float], plain: SIMD3<Float>) -> PreviewMesh {
        let (nx, ny, nz) = (g.n[0], g.n[1], g.n[2])
        guard nx > 0, ny > 0, nz > 0, density.count == nx * ny * nz else { return PreviewMesh() }
        func solid(_ i: Int, _ j: Int, _ k: Int) -> Bool {
            i >= 0 && j >= 0 && k >= 0 && i < nx && j < ny && k < nz && density[i + nx * (j + ny * k)] >= 0.5
        }
        var pos = [Float](), nor = [Float](), idx = [UInt32]()
        let h = Float(g.h), o = SIMD3<Float>(Float(g.origin.x), Float(g.origin.y), Float(g.origin.z))
        // Per axis and side: the face's normal and its corners counter-clockwise seen from outside.
        let faces: [(SIMD3<Int>, [SIMD3<Float>])] = [
            (SIMD3(-1, 0, 0), [SIMD3(0, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 1), SIMD3(0, 1, 0)]),
            (SIMD3(1, 0, 0), [SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(1, 1, 1), SIMD3(1, 0, 1)]),
            (SIMD3(0, -1, 0), [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 0, 1), SIMD3(0, 0, 1)]),
            (SIMD3(0, 1, 0), [SIMD3(0, 1, 0), SIMD3(0, 1, 1), SIMD3(1, 1, 1), SIMD3(1, 1, 0)]),
            (SIMD3(0, 0, -1), [SIMD3(0, 0, 0), SIMD3(0, 1, 0), SIMD3(1, 1, 0), SIMD3(1, 0, 0)]),
            (SIMD3(0, 0, 1), [SIMD3(0, 0, 1), SIMD3(1, 0, 1), SIMD3(1, 1, 1), SIMD3(0, 1, 1)]),
        ]
        for k in 0..<nz {
            for j in 0..<ny {
                for i in 0..<nx where solid(i, j, k) {
                    for (d, corners) in faces where !solid(i + d.x, j + d.y, k + d.z) {
                        let first = UInt32(pos.count / 3)
                        let cell = o + SIMD3(Float(i), Float(j), Float(k)) * h
                        for c in corners {
                            let p = cell + c * h
                            pos += [p.x, p.y, p.z]
                            nor += [Float(d.x), Float(d.y), Float(d.z)]
                        }
                        idx += [first, first + 1, first + 2, first, first + 2, first + 3]
                    }
                }
            }
        }
        let n = pos.count / 3
        var out = PreviewMesh()
        guard n > 0 else { return out }
        var colors = [Float](repeating: 1, count: 4 * n)
        for v in 0..<n {
            colors[4 * v] = plain.x
            colors[4 * v + 1] = plain.y
            colors[4 * v + 2] = plain.z
        }
        out.positions = pos.withUnsafeBufferPointer { Data(buffer: $0) }
        out.normals = nor.withUnsafeBufferPointer { Data(buffer: $0) }
        out.colors = colors.withUnsafeBufferPointer { Data(buffer: $0) }
        out.indices = idx.withUnsafeBufferPointer { Data(buffer: $0) }
        out.vertexCount = n
        out.triangleCount = idx.count / 3
        out.min = o
        out.max = o + SIMD3(Float(nx), Float(ny), Float(nz)) * h
        out.voxels = true
        return out
    }

    /// The SceneKit geometry over the packed buffers.
    func geometry() -> SCNGeometry {
        let v = SCNGeometrySource(data: positions, semantic: .vertex, vectorCount: vertexCount, usesFloatComponents: true,
                                  componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let n = SCNGeometrySource(data: normals, semantic: .normal, vectorCount: vertexCount, usesFloatComponents: true,
                                  componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let c = SCNGeometrySource(data: colors, semantic: .color, vectorCount: vertexCount, usesFloatComponents: true,
                                  componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: 16)
        let e = SCNGeometryElement(data: indices, primitiveType: .triangles, primitiveCount: triangleCount, bytesPerIndex: 4)
        let g = SCNGeometry(sources: [v, n, c], elements: [e])
        let m = SCNMaterial()
        m.lightingModel = .blinn
        m.diffuse.contents = GenerateColor.white
        m.specular.contents = GenerateColor(white: 0.25, alpha: 1)
        m.shininess = 0.35
        // The engine's surfaces face outward; both sides keep a half-finished one readable.
        m.isDoubleSided = true
        g.materials = [m]
        return g
    }
}

// MARK: Scene

/// The study in 3D with SceneKit: the design space, its regions (translucent boxes, cylinders
/// and spheres), load arrows and torque arcs, and the picked candidate's surface coloured by
/// stress. World z is up in millimetres; everything hangs under a root turned a quarter turn
/// about x for SceneKit's y up, so study coordinates go in unchanged.
@MainActor
final class GenerateScene {
    let scene = SCNScene()
    let cameraNode = SCNNode()
    let root = SCNNode()
    private let spaceNode = SCNNode()
    private let regionsNode = SCNNode()
    private let resultNode = SCNNode()

    /// Orbit about `target`, world mm: yaw about z from +x, pitch above the xy plane.
    var target = Vec3.zero
    var yaw = -0.9
    var pitch = 0.45
    var distance = 200.0

    private var shownSpace: (Vec3, Vec3)?
    private var shownRegions: Int?
    private var shownResult: (version: Int, index: Int?)?
    private var shownLive: Int?

    static let supportColor = SIMD3<Double>(0.25, 0.55, 1.0)
    static let loadColor = SIMD3<Double>(1.0, 0.58, 0.12)
    static let keepOutColor = SIMD3<Double>(0.95, 0.30, 0.30)
    static let keepInColor = SIMD3<Double>(0.30, 0.85, 0.45)

    init(theme: ViewportTheme) {
        root.simdEulerAngles.x = -.pi / 2
        scene.rootNode.addChildNode(root)
        [spaceNode, resultNode, regionsNode].forEach(root.addChildNode)
        scene.background.contents = Self.backdrop(theme)

        let camera = SCNCamera()
        camera.fieldOfView = 40
        camera.zNear = 0.5
        camera.zFar = 100_000
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)
        // A headlight that follows the orbit, a key light and some fill.
        let head = SCNNode()
        head.light = SCNLight()
        head.light?.type = .directional
        head.light?.intensity = 650
        head.simdEulerAngles = SIMD3(-0.35, 0.3, 0)
        cameraNode.addChildNode(head)
        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .ambient
        fill.light?.intensity = 420
        scene.rootNode.addChildNode(fill)
        applyCamera()
    }

    nonisolated private static func backdrop(_ theme: ViewportTheme) -> CGImage? {
        let (top, bottom) = (theme.backgroundTop, theme.backgroundBottom)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: 4, height: 256, bitsPerComponent: 8, bytesPerRow: 16, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(colorsSpace: space, colors: [
                  CGColor(srgbRed: CGFloat(bottom.x), green: CGFloat(bottom.y), blue: CGFloat(bottom.z), alpha: 1),
                  CGColor(srgbRed: CGFloat(top.x), green: CGFloat(top.y), blue: CGFloat(top.z), alpha: 1),
              ] as CFArray, locations: [0, 1]) else { return nil }
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: 256), options: [])
        return ctx.makeImage()
    }

    // MARK: Camera

    /// From the target toward the eye, world.
    var back: Vec3 { Vec3(cos(pitch) * cos(yaw), cos(pitch) * sin(yaw), sin(pitch)) }

    /// World (z up) to SceneKit (y up).
    nonisolated static func toScene(_ p: Vec3) -> SIMD3<Float> { SIMD3(Float(p.x), Float(p.z), Float(-p.y)) }

    func applyCamera() {
        let eye = target + back * distance
        cameraNode.simdPosition = Self.toScene(eye)
        cameraNode.simdLook(at: Self.toScene(target), up: SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
        cameraNode.camera?.zNear = max(0.05, distance * 0.002)
        cameraNode.camera?.zFar = distance * 20 + 1000
    }

    func orbit(dx: Double, dy: Double) {
        moved = true
        yaw -= dx * 0.008
        pitch = min(max(pitch + dy * 0.008, -1.55), 1.55)
        applyCamera()
    }

    /// Pans by a drag of `dx`, `dy` points (y up) in a view `height` points tall: the picture
    /// follows the pointer.
    func pan(dx: Double, dy: Double, height: Double) {
        moved = true
        let fov = Double(cameraNode.camera?.fieldOfView ?? 40) * .pi / 180
        let perPoint = 2 * distance * tan(fov / 2) / max(height, 1)
        let right = simd_normalize(simd_cross(Vec3(0, 0, 1), back))
        let up = simd_cross(back, right)
        target -= (right * dx + up * dy) * perPoint
        applyCamera()
    }

    func zoom(_ factor: Double) {
        moved = true
        distance = min(max(distance * factor, 1), 1e6)
        applyCamera()
    }

    /// Width over height of the view showing the scene; the fit uses the narrower field.
    private(set) var aspect = 1.6
    /// The box last framed, and whether the camera moved since (a resize then keeps the move).
    private var framed: (Vec3, Vec3)?
    private var moved = false
    /// What the camera was last homed for: the project study, or the template's space.
    private var homedFor: String?

    /// The view showing the scene is now `width` by `height` points: frames the box again
    /// for the new shape unless the camera was moved by hand.
    func resized(width: Double, height: Double) {
        guard width > 1, height > 1 else { return }
        let a = width / height
        guard abs(a - aspect) > 0.01 else { return }
        aspect = a
        if !moved, let (lo, hi) = framed { fit(lo, hi) }
    }

    /// Frames the box `lo...hi` in the narrower of the two fields of view, with room for the
    /// cards drawn over the viewport.
    func fit(_ lo: Vec3, _ hi: Vec3) {
        framed = (lo, hi)
        moved = false
        target = (lo + hi) / 2
        let radius = max(simd_length(hi - lo) / 2, 1)
        let vertical = Double(cameraNode.camera?.fieldOfView ?? 40) * .pi / 180
        let horizontal = 2 * atan(tan(vertical / 2) * aspect)
        let fov = min(vertical, horizontal)
        distance = radius / sin(fov / 2) * 1.22
        applyCamera()
    }

    func home(_ study: Study) {
        yaw = -0.9
        pitch = 0.45
        fit(simd_min(study.min, study.max), simd_max(study.min, study.max))
    }

    // MARK: Content

    /// Brings the scene up to date: the design space when it changed, the regions, and the
    /// picked candidate's surface in the Result display.
    func update(_ model: GenerateModel) {
        let s = model.study
        let lo = simd_min(s.min, s.max), hi = simd_max(s.min, s.max)
        if shownSpace == nil || shownSpace! != (lo, hi) {
            shownSpace = (lo, hi)
            buildSpace(lo, hi)
        }
        // A new study (or a template's new space) is framed whole; edits to the open
        // project study's size keep the camera where it is.
        let homeKey = model.projectStudy.map { "study:\($0)" } ?? "space:\(lo)\(hi)"
        if homedFor != homeKey {
            homedFor = homeKey
            home(s)
        }
        let result = model.display == .result
        var hasher = Hasher()
        hasher.combine(s.supports)
        hasher.combine(s.cases)
        hasher.combine(s.keepOut)
        hasher.combine(s.keepIn)
        hasher.combine(lo)
        hasher.combine(hi)
        hasher.combine(model.selection)
        hasher.combine(model.activeCase)
        hasher.combine(result)
        let key = hasher.finalize()
        if shownRegions != key {
            shownRegions = key
            buildRegions(model, faint: result)
        }
        // While a run solves, its shape as it stands (the coarse live surface).
        if model.running, let live = model.livePreview {
            if shownLive != model.liveVersion {
                shownLive = model.liveVersion
                shownResult = nil
                resultNode.childNodes.forEach { $0.removeFromParentNode() }
                if !live.isEmpty { resultNode.addChildNode(SCNNode(geometry: live.geometry())) }
            }
            return
        }
        if shownLive != nil {
            shownLive = nil
            shownResult = nil
        }
        let index = result ? model.selected : nil
        if shownResult == nil || shownResult!.version != model.previewsVersion || shownResult!.index != index {
            shownResult = (model.previewsVersion, index)
            resultNode.childNodes.forEach { $0.removeFromParentNode() }
            if let index, let p = model.previews[safe: index], !p.isEmpty {
                resultNode.addChildNode(SCNNode(geometry: p.geometry()))
            }
        }
    }

    private func buildSpace(_ lo: Vec3, _ hi: Vec3) {
        spaceNode.childNodes.forEach { $0.removeFromParentNode() }
        // The design space's edges.
        let c = (0..<8).map { i in Vec3(i & 1 == 0 ? lo.x : hi.x, i & 2 == 0 ? lo.y : hi.y, i & 4 == 0 ? lo.z : hi.z) }
        let edges: [(Int, Int)] = [(0, 1), (2, 3), (4, 5), (6, 7), (0, 2), (1, 3), (4, 6), (5, 7), (0, 4), (1, 5), (2, 6), (3, 7)]
        spaceNode.addChildNode(Self.lines(edges.map { (c[$0.0], c[$0.1]) }, color: GenerateColor(white: 0.85, alpha: 0.55)))
        // A floor grid under it, 10 mm or coarser.
        let size = hi - lo
        let step = [1.0, 2, 5, 10, 20, 50, 100, 200, 500].first { max(size.x, size.y) / $0 <= 24 } ?? 1000
        var grid: [(Vec3, Vec3)] = []
        var x = (lo.x / step).rounded(.down) * step
        while x <= hi.x + 1e-9 { grid.append((Vec3(x, lo.y, lo.z), Vec3(x, hi.y, lo.z))); x += step }
        var y = (lo.y / step).rounded(.down) * step
        while y <= hi.y + 1e-9 { grid.append((Vec3(lo.x, y, lo.z), Vec3(hi.x, y, lo.z))); y += step }
        spaceNode.addChildNode(Self.lines(grid, color: GenerateColor(white: 0.7, alpha: 0.16)))
        // The axes at the corner: x red, y green, z blue.
        let l = max(size.max() * 0.12, 2)
        for (a, color) in [(Vec3(1, 0, 0), GenerateColor.systemRed), (Vec3(0, 1, 0), .systemGreen), (Vec3(0, 0, 1), .systemBlue)] {
            spaceNode.addChildNode(Self.lines([(lo, lo + a * l)], color: color))
        }
    }

    private func buildRegions(_ model: GenerateModel, faint: Bool) {
        regionsNode.childNodes.forEach { $0.removeFromParentNode() }
        let s = model.study
        let scale = max(s.size.max(), 1)
        func alpha(_ key: GenerateModel.RegionKey, dim: Bool = false) -> Double {
            if model.selection == key { return 0.5 }
            if faint { return 0.1 }
            return dim ? 0.1 : 0.24
        }
        for sup in s.supports {
            let key = GenerateModel.RegionKey.support(sup.id)
            regionsNode.addChildNode(Self.region(sup.region, color: Self.supportColor, alpha: alpha(key), name: key.name, selected: model.selection == key))
        }
        if !faint {
            for k in s.keepOut {
                let key = GenerateModel.RegionKey.keepOut(k.id)
                regionsNode.addChildNode(Self.region(k.region, color: Self.keepOutColor, alpha: alpha(key), name: key.name, selected: model.selection == key))
            }
            for k in s.keepIn {
                let key = GenerateModel.RegionKey.keepIn(k.id)
                regionsNode.addChildNode(Self.region(k.region, color: Self.keepInColor, alpha: alpha(key), name: key.name, selected: model.selection == key))
            }
        }
        for (ci, lc) in s.cases.enumerated() {
            let other = ci != model.activeCase
            for load in lc.loads {
                let key = GenerateModel.RegionKey.load(load.id)
                let a = alpha(key, dim: other)
                regionsNode.addChildNode(Self.region(load.region, color: Self.loadColor, alpha: a, name: key.name, selected: model.selection == key))
                let glyph = Self.loadGlyph(load, scale: scale, opacity: other && model.selection != key ? 0.35 : 1)
                glyph.name = key.name
                regionsNode.addChildNode(glyph)
            }
        }
    }

    // MARK: Builders

    static func material(_ rgb: SIMD3<Double>, alpha: Double, constant: Bool = true) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = constant ? .constant : .blinn
        m.diffuse.contents = GenerateColor(red: rgb.x, green: rgb.y, blue: rgb.z, alpha: alpha)
        if alpha < 1 {
            m.transparencyMode = .dualLayer
            m.writesToDepthBuffer = false
            m.isDoubleSided = true
        }
        return m
    }

    /// A translucent region; the picked one also shows its outline.
    static func region(_ r: StudyRegion, color: SIMD3<Double>, alpha: Double, name: String, selected: Bool) -> SCNNode {
        let g: SCNGeometry
        let node = SCNNode()
        switch r.shape {
        case .box:
            let (lo, hi) = r.bounds
            let d = simd_max(hi - lo, Vec3(repeating: 0.05))
            g = SCNBox(width: d.x, height: d.y, length: d.z, chamferRadius: 0)
            node.simdPosition = SIMD3<Float>((lo + hi) / 2)
        case .cylinder:
            g = SCNCylinder(radius: max(r.radius, 0.05), height: max(r.length, 0.05))
            node.simdPosition = SIMD3<Float>(r.middle)
            node.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: SIMD3<Float>(r.unitAxis))
        case .tube:
            g = SCNTube(innerRadius: max(min(r.inner, r.radius - 0.05), 0.01), outerRadius: max(r.radius, 0.06), height: max(r.length, 0.05))
            node.simdPosition = SIMD3<Float>(r.middle)
            node.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: SIMD3<Float>(r.unitAxis))
        case .sphere:
            g = SCNSphere(radius: max(r.radius, 0.05))
            node.simdPosition = SIMD3<Float>(r.center)
        }
        g.materials = [material(color, alpha: alpha)]
        node.geometry = g
        node.name = name
        node.renderingOrder = 10
        if selected {
            let (lo, hi) = r.bounds
            let c = (0..<8).map { i in Vec3(i & 1 == 0 ? lo.x : hi.x, i & 2 == 0 ? lo.y : hi.y, i & 4 == 0 ? lo.z : hi.z) }
            let edges: [(Int, Int)] = [(0, 1), (2, 3), (4, 5), (6, 7), (0, 2), (1, 3), (4, 6), (5, 7), (0, 4), (1, 5), (2, 6), (3, 7)]
            let outline = lines(edges.map { (c[$0.0], c[$0.1]) }, color: GenerateColor(red: color.x, green: color.y, blue: color.z, alpha: 1))
            // The outline is in world coordinates, beside the placed region.
            let wrap = SCNNode()
            wrap.addChildNode(node)
            wrap.addChildNode(outline)
            wrap.name = name
            return wrap
        }
        return node
    }

    /// Line segments, world mm.
    static func lines(_ segments: [(Vec3, Vec3)], color: GenerateColor) -> SCNNode {
        var pts: [SIMD3<Float>] = []
        pts.reserveCapacity(segments.count * 2)
        for (a, b) in segments { pts.append(SIMD3<Float>(a)); pts.append(SIMD3<Float>(b)) }
        let data = pts.withUnsafeBufferPointer { p in
            Data(bytes: p.baseAddress!, count: p.count * MemoryLayout<SIMD3<Float>>.stride)
        }
        let src = SCNGeometrySource(data: data, semantic: .vertex, vectorCount: pts.count, usesFloatComponents: true,
                                    componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0,
                                    dataStride: MemoryLayout<SIMD3<Float>>.stride)
        let idx = (0..<UInt32(pts.count)).map { $0 }
        let el = SCNGeometryElement(indices: idx, primitiveType: .line)
        let g = SCNGeometry(sources: [src], elements: [el])
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = color
        g.materials = [m]
        return SCNNode(geometry: g)
    }

    /// A rod from `a` to `b`, world mm.
    static func rod(_ a: Vec3, _ b: Vec3, radius: Double, material m: SCNMaterial) -> SCNNode {
        let d = b - a, l = simd_length(d)
        let g = SCNCylinder(radius: radius, height: max(l, 1e-3))
        g.radialSegmentCount = 12
        g.materials = [m]
        let n = SCNNode(geometry: g)
        n.simdPosition = SIMD3<Float>((a + b) / 2)
        if l > 0 { n.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: SIMD3<Float>(d / l)) }
        return n
    }

    /// An arrow whose tip touches `tip`, pointing along `direction`.
    static func arrow(tip: Vec3, direction: Vec3, length: Double, material m: SCNMaterial) -> SCNNode {
        let group = SCNNode()
        let l = simd_length(direction)
        guard l > 0 else { return group }
        let u = direction / l
        let head = length * 0.28, r = length * 0.035
        group.addChildNode(rod(tip - u * length, tip - u * head, radius: r, material: m))
        let cone = SCNCone(topRadius: 0, bottomRadius: r * 3, height: head)
        cone.radialSegmentCount = 16
        cone.materials = [m]
        let c = SCNNode(geometry: cone)
        c.simdPosition = SIMD3<Float>(tip - u * head / 2)
        c.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: SIMD3<Float>(u))
        group.addChildNode(c)
        return group
    }

    /// The load's glyph: an arrow into the region for a force, arrows over its face for a
    /// pressure, an arc with a head about the axis for a torque (right-hand rule).
    static func loadGlyph(_ load: StudyLoad, scale: Double, opacity: Double) -> SCNNode {
        let m = material(loadColor, alpha: opacity, constant: false)
        m.emission.contents = GenerateColor(red: loadColor.x * 0.35, green: loadColor.y * 0.35, blue: loadColor.z * 0.35, alpha: 1)
        let length = scale * 0.22
        switch load.kind {
        case .force:
            return arrow(tip: load.region.middle, direction: load.force, length: length, material: m)
        case .pressure:
            let group = SCNNode()
            let d = load.direction
            guard simd_length(d) > 0 else { return group }
            let (lo, hi) = load.region.bounds
            let a = abs(d.x) >= abs(d.y) && abs(d.x) >= abs(d.z) ? 0 : (abs(d.y) >= abs(d.z) ? 1 : 2)
            let (b, c) = ((a + 1) % 3, (a + 2) % 3)
            for i in 0..<3 {
                for j in 0..<3 {
                    var tip = Vec3.zero
                    tip[a] = d[a] < 0 ? hi[a] : lo[a]
                    tip[b] = lo[b] + (hi[b] - lo[b]) * (Double(i) + 0.5) / 3
                    tip[c] = lo[c] + (hi[c] - lo[c]) * (Double(j) + 0.5) / 3
                    group.addChildNode(arrow(tip: tip, direction: d, length: length * 0.45, material: m))
                }
            }
            return group
        case .torque:
            let group = SCNNode()
            let axis = simd_length(load.axis) > 0 ? simd_normalize(load.axis) : Vec3(0, 0, 1)
            let (lo, hi) = load.region.bounds
            let radius = max(simd_length(hi - lo) * 0.35, scale * 0.06)
            // A frame about the axis.
            let helper = abs(axis.z) < 0.9 ? Vec3(0, 0, 1) : Vec3(1, 0, 0)
            let e1 = simd_normalize(simd_cross(axis, helper)), e2 = simd_cross(axis, e1)
            let sign: Double = load.moment >= 0 ? 1 : -1
            let sweep = 1.5 * Double.pi, steps = 28
            func point(_ t: Double) -> Vec3 { load.center + (e1 * cos(sign * t) + e2 * sin(sign * t)) * radius }
            for k in 0..<steps {
                group.addChildNode(rod(point(sweep * Double(k) / Double(steps)), point(sweep * Double(k + 1) / Double(steps)),
                                       radius: length * 0.03, material: m))
            }
            let end = point(sweep)
            let tangent = (-e1 * sin(sign * sweep) + e2 * cos(sign * sweep)) * sign
            group.addChildNode(arrow(tip: end + tangent * length * 0.25, direction: tangent, length: length * 0.3, material: m))
            group.addChildNode(rod(load.center - axis * radius * 0.6, load.center + axis * radius * 0.6, radius: length * 0.015, material: m))
            return group
        }
    }

    // MARK: Picking and dragging

    /// The region under a view point.
    static func key(of node: SCNNode) -> GenerateModel.RegionKey? {
        var n: SCNNode? = node
        while let x = n {
            if let name = x.name, let k = GenerateModel.RegionKey(name: name) { return k }
            n = x.parent
        }
        return nil
    }

    /// A view ray, world mm: origin and unit direction.
    func ray(_ view: SCNView, _ p: CGPoint) -> (Vec3, Vec3) {
        let a = view.unprojectPoint(SCNVector3(Float(p.x), Float(p.y), 0))
        let b = view.unprojectPoint(SCNVector3(Float(p.x), Float(p.y), 1))
        let wa = root.simdConvertPosition(SIMD3(Float(a.x), Float(a.y), Float(a.z)), from: nil)
        let wb = root.simdConvertPosition(SIMD3(Float(b.x), Float(b.y), Float(b.z)), from: nil)
        let o = Vec3(wa), d = Vec3(wb) - Vec3(wa)
        return (o, simd_length(d) > 0 ? simd_normalize(d) : -back)
    }

    /// Where the view ray at `p` meets the plane through `origin` with normal `normal`.
    func hit(_ view: SCNView, _ p: CGPoint, plane origin: Vec3, normal: Vec3) -> Vec3? {
        let (o, d) = ray(view, p)
        let den = simd_dot(d, normal)
        guard abs(den) > 1e-6 else { return nil }
        let t = simd_dot(origin - o, normal) / den
        return t > 0 ? o + d * t : nil
    }

    /// The world axis closest to the view direction: dragging moves regions across it.
    var dragNormal: Vec3 {
        let b = back
        let a = abs(b.x) >= abs(b.y) && abs(b.x) >= abs(b.z) ? 0 : (abs(b.y) >= abs(b.z) ? 1 : 2)
        var n = Vec3.zero
        n[a] = 1
        return n
    }

    // MARK: Thumbnails

    /// A still of a candidate's surface from the default orbit, for the gallery. Builds its own
    /// small scene, so it runs off the main actor.
    nonisolated static func thumbnail(_ preview: PreviewMesh, size: CGSize, theme: ViewportTheme) -> CGImage? {
        guard !preview.isEmpty else { return nil }
        let scene = SCNScene()
        scene.background.contents = backdrop(theme)
        let root = SCNNode()
        root.simdEulerAngles.x = -.pi / 2
        scene.rootNode.addChildNode(root)
        root.addChildNode(SCNNode(geometry: preview.geometry()))
        let camera = SCNCamera()
        camera.fieldOfView = 40
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)
        let head = SCNNode()
        head.light = SCNLight()
        head.light?.type = .directional
        head.light?.intensity = 650
        head.simdEulerAngles = SIMD3(-0.35, 0.3, 0)
        cameraNode.addChildNode(head)
        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .ambient
        fill.light?.intensity = 420
        scene.rootNode.addChildNode(fill)
        // The default orbit, framing the surface's box.
        let lo = Vec3(preview.min), hi = Vec3(preview.max)
        let yaw = -0.9, pitch = 0.45
        let back = Vec3(cos(pitch) * cos(yaw), cos(pitch) * sin(yaw), sin(pitch))
        let target = (lo + hi) / 2
        let radius = max(simd_length(hi - lo) / 2, 1)
        let vertical = 40.0 * .pi / 180
        let aspect = size.width / max(size.height, 1)
        let fov = min(vertical, 2 * atan(tan(vertical / 2) * aspect))
        let distance = radius / sin(fov / 2) * 1.22
        cameraNode.simdPosition = toScene(target + back * distance)
        cameraNode.simdLook(at: toScene(target), up: SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
        camera.zNear = max(0.05, distance * 0.002)
        camera.zFar = distance * 20 + 1000
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = scene
        renderer.pointOfView = cameraNode
        let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
        #if os(macOS)
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        return image.cgImage
        #endif
    }

    // MARK: Camera state

    /// Where the camera is, kept by the model so a return to Generate finds the same view.
    struct CameraState {
        var target: Vec3
        var yaw: Double
        var pitch: Double
        var distance: Double
        var homedFor: String?
        var moved: Bool
        var framed: (Vec3, Vec3)?
    }

    var cameraState: CameraState {
        get { CameraState(target: target, yaw: yaw, pitch: pitch, distance: distance, homedFor: homedFor, moved: moved, framed: framed) }
        set {
            target = newValue.target
            yaw = newValue.yaw
            pitch = newValue.pitch
            distance = newValue.distance
            homedFor = newValue.homedFor
            moved = newValue.moved
            framed = newValue.framed
            applyCamera()
        }
    }
}

extension Image {
    init(generate image: GenerateImage) {
        #if os(macOS)
        self.init(nsImage: image)
        #else
        self.init(uiImage: image)
        #endif
    }
}
