import MetalKit
import simd

/// Colours the viewport draws with besides the scene's own: each front end has its look.
struct ViewportTheme {
    var backgroundTop: SIMD4<Float>
    var backgroundBottom: SIMD4<Float>
    var highlight: SIMD4<Float>
    var hover: SIMD4<Float>
    var edge: SIMD4<Float>
    /// Use the engine's background instead of the theme's.
    var engineBackground = false
    /// Scales the grid's opacity, for dark backgrounds.
    var gridOpacity: Float = 1
}

/// What is selected or under the cursor, for the highlight.
struct Highlight: Equatable {
    var faces: [Int: [Int]] = [:]
    var edges: [Int: [Int]] = [:]
    var bodies: Set<Int> = []
    var hoverFace: (mesh: Int, face: Int)?
    var hoverEdge: (mesh: Int, edge: Int)?

    static func == (a: Highlight, b: Highlight) -> Bool {
        a.faces == b.faces && a.edges == b.edges && a.bodies == b.bodies
            && a.hoverFace?.mesh == b.hoverFace?.mesh && a.hoverFace?.face == b.hoverFace?.face
            && a.hoverEdge?.mesh == b.hoverEdge?.mesh && a.hoverEdge?.edge == b.hoverEdge?.edge
    }
}

private struct Frame {
    var viewProj: simd_float4x4
    var view: simd_float4x4
    var bgTop: SIMD4<Float>
    var bgBottom: SIMD4<Float>
    var highlight: SIMD4<Float>
    var hover: SIMD4<Float>
    var viewport: SIMD2<Float>
    var pixelScale: Float
    var edgeBias: Float
    var clipPlane = SIMD4<Float>(0, 0, 1, 0)
    var clipOn: Float = 0
}

private struct MeshUniform {
    var color: SIMD4<Float>
    var selected: (Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32) =
        (-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1)
    var selectedCount: Int32 = 0
    var hovered: Int32 = -1
    var bodySelected: Int32 = 0
    var pad: Int32 = 0
}

private struct Segment {
    var a: (Float, Float, Float)
    var b: (Float, Float, Float)
    var color: SIMD4<Float>
    var width: Float
    var onTop: Float
}

private struct GPUMesh {
    var positions: MTLBuffer
    var normals: MTLBuffer
    var faces: MTLBuffer
    var indices: MTLBuffer
    var indexCount: Int
    var color: SIMD4<Float>
    /// Axis-aligned bounds, for the section caps.
    var lo: SIMD3<Float>
    var hi: SIMD3<Float>
}

/// Draws the engine's scene with Metal: background, grid, bodies, edges and sketch lines.
final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private var meshPipeline: MTLRenderPipelineState!
    private var linePipeline: MTLRenderPipelineState!
    private var backgroundPipeline: MTLRenderPipelineState!
    private var clipMaskPipeline: MTLRenderPipelineState!
    private var capPipeline: MTLRenderPipelineState!
    private var stencilFlip: MTLDepthStencilState!
    private var capDepth: MTLDepthStencilState!
    private var depthOn: MTLDepthStencilState!
    private var depthRead: MTLDepthStencilState!
    private var depthOff: MTLDepthStencilState!

    private var meshes: [GPUMesh] = []
    private var lineBuffer: MTLBuffer?
    private var lineCount = 0
    private var gridBuffer: MTLBuffer?
    private var gridCount = 0
    private var overlayBuffer: MTLBuffer?
    private var overlayCount = 0

    /// The section that cuts the view (B-15): what lies on the plane's positive side is not
    /// drawn, and each cut solid body gets a hatched cap on the plane. `nil` draws everything.
    var sectionPlane: SectionPlane? { didSet { if sectionPlane != oldValue { rebuildCaps(); requestDraw() } } }
    /// Hatch the caps (the engine's `hatch` flag); off draws them in the body's shaded colour.
    var sectionHatch = true { didSet { if sectionHatch != oldValue { requestDraw() } } }
    /// One quad on the plane for each opaque body the plane crosses: (mesh index, 4 corners).
    private var caps: [(mesh: Int, corners: MTLBuffer)] = []
    /// How many bodies get a cap now (for the self test and the accessibility value).
    var capCount: Int { caps.count }

    var camera = OrbitCamera() { didSet { requestDraw() } }
    var radius: Double = 100
    var theme: ViewportTheme { didSet { view?.clearColor = theme.clearColor; requestDraw() } }
    var highlight = Highlight()
    var pointSize: CGSize = .init(width: 1, height: 1) { didSet { if pointSize != oldValue { requestDraw() } } }
    private var scene = SceneData()
    /// The view drawn into. It draws on demand (a new scene, camera, highlight or size), not
    /// on a timer: an idle viewport costs nothing and leaves the main thread free.
    private weak var view: MTKView?

    /// The bodies' GPU buffers of the last scene uploaded, shared by every renderer on the same
    /// device: a viewport made again (a workspace switched back to) does not upload them again.
    nonisolated(unsafe) private static var shared: (serial: Int, device: ObjectIdentifier, meshes: [GPUMesh])?

    func requestDraw() {
        #if os(macOS)
        view?.needsDisplay = true
        #else
        view?.setNeedsDisplay()
        #endif
    }

    init?(view: MTKView, theme: ViewportTheme) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.theme = theme
        super.init()
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = Self.depthStencilFormat
        view.sampleCount = 4
        view.clearColor = theme.clearColor
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        self.view = view
        guard buildPipelines(view) else { return nil }
    }

    /// Depth plus a stencil, which the section caps count surfaces in.
    static let depthStencilFormat: MTLPixelFormat = .depth32Float_stencil8

    private func buildPipelines(_ view: MTKView) -> Bool {
        guard let lib = device.makeDefaultLibrary() else { return false }
        func pipeline(_ v: String, _ f: String, blend: Bool, depth: Bool = true, colour: Bool = true) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: v)
            d.fragmentFunction = lib.makeFunction(name: f)
            d.colorAttachments[0].pixelFormat = view.colorPixelFormat
            if !colour { d.colorAttachments[0].writeMask = [] }
            d.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            if view.depthStencilPixelFormat == .depth32Float_stencil8 { d.stencilAttachmentPixelFormat = view.depthStencilPixelFormat }
            d.rasterSampleCount = view.sampleCount
            if blend {
                let c = d.colorAttachments[0]!
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .sourceAlpha
                c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .one
                c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        meshPipeline = pipeline("mesh_vertex", "mesh_fragment", blend: true)
        linePipeline = pipeline("line_vertex", "line_fragment", blend: true)
        backgroundPipeline = pipeline("background_vertex", "background_fragment", blend: false)
        clipMaskPipeline = pipeline("mesh_vertex", "clip_mask_fragment", blend: false, colour: false)
        capPipeline = pipeline("cap_vertex", "cap_fragment", blend: false)
        func depth(_ compare: MTLCompareFunction, write: Bool) -> MTLDepthStencilState? {
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = compare
            d.isDepthWriteEnabled = write
            return device.makeDepthStencilState(descriptor: d)
        }
        depthOn = depth(.lessEqual, write: true)
        depthRead = depth(.lessEqual, write: false)
        depthOff = depth(.always, write: false)
        // Caps: every surface left after the clip flips the stencil, whatever its depth; the cap
        // then draws (depth tested) where the count is odd and sets it back to zero.
        let flip = MTLDepthStencilDescriptor()
        flip.depthCompareFunction = .always
        flip.isDepthWriteEnabled = false
        let invert = MTLStencilDescriptor()
        invert.stencilCompareFunction = .always
        invert.depthStencilPassOperation = .invert
        invert.writeMask = 0x01
        flip.frontFaceStencil = invert
        flip.backFaceStencil = invert
        stencilFlip = device.makeDepthStencilState(descriptor: flip)
        let cap = MTLDepthStencilDescriptor()
        cap.depthCompareFunction = .lessEqual
        cap.isDepthWriteEnabled = true
        let inside = MTLStencilDescriptor()
        inside.stencilCompareFunction = .notEqual
        inside.readMask = 0x01
        inside.writeMask = 0x01
        inside.stencilFailureOperation = .keep
        inside.depthFailureOperation = .zero
        inside.depthStencilPassOperation = .zero
        cap.frontFaceStencil = inside
        cap.backFaceStencil = inside
        capDepth = device.makeDepthStencilState(descriptor: cap)
        return meshPipeline != nil && linePipeline != nil && backgroundPipeline != nil
            && clipMaskPipeline != nil && capPipeline != nil
    }

    /// Takes a new scene from the engine.
    func update(scene: SceneData) {
        Perf.measure("scene.upload") { apply(scene) }
    }

    private func apply(_ scene: SceneData) {
        self.scene = scene
        radius = Double(scene.radius)
        let dev = ObjectIdentifier(device)
        if scene.serial != 0, let s = Self.shared, s.serial == scene.serial, s.device == dev {
            meshes = s.meshes
        } else {
            meshes = scene.meshes.compactMap(upload)
            if scene.serial != 0 { Self.shared = (scene.serial, dev, meshes) }
        }
        (lineBuffer, lineCount) = segments(scene.lines)
        (gridBuffer, gridCount) = segments(themedGrid(scene.grid))
        rebuildOverlay()
        rebuildCaps()
        requestDraw()
    }

    /// Takes the camera-dependent lines (grid, axes, edges) and keeps the bodies' buffers.
    func updateGuides(_ g: SceneData) {
        Perf.measure("guides.upload") {
            radius = Double(g.radius)
            scene.lines = g.lines
            scene.grid = g.grid
            (lineBuffer, lineCount) = segments(g.lines)
            (gridBuffer, gridCount) = segments(themedGrid(g.grid))
        }
        requestDraw()
    }

    private func themedGrid(_ grid: [SceneData.Line]) -> [SceneData.Line] {
        theme.gridOpacity == 1 ? grid : grid.map { l in
            var l = l
            l.color.w *= theme.gridOpacity
            return l
        }
    }

    func setHighlight(_ h: Highlight) {
        guard h != highlight else { return }
        highlight = h
        rebuildOverlay()
        requestDraw()
    }

    /// Writes the vectors as packed float3 (the shaders' layout) straight into a new buffer.
    private func packed(_ v: [SIMD3<Float>], count n: Int) -> MTLBuffer? {
        guard let b = device.makeBuffer(length: max(n, 1) * 12, options: .storageModeShared) else { return nil }
        let out = b.contents().bindMemory(to: Float.self, capacity: n * 3)
        if v.count == n {
            v.withUnsafeBufferPointer { src in
                for j in 0..<n {
                    out[j * 3] = src[j].x
                    out[j * 3 + 1] = src[j].y
                    out[j * 3 + 2] = src[j].z
                }
            }
        } else {
            out.initialize(repeating: 0, count: n * 3)
        }
        return b
    }

    private func upload(_ m: SceneData.Mesh) -> GPUMesh? {
        let n = m.positions.count
        guard n > 0, !m.indices.isEmpty,
              let p = packed(m.positions, count: n),
              let nb = packed(m.normals, count: n),
              let f = device.makeBuffer(length: n * 4, options: .storageModeShared),
              let i = m.indices.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }) else { return nil }
        // The B-rep face of each vertex, from its triangles.
        let faces = f.contents().bindMemory(to: UInt32.self, capacity: n)
        faces.initialize(repeating: 0, count: n)
        m.indices.withUnsafeBufferPointer { idx in
            m.triFace.withUnsafeBufferPointer { tf in
                for t in 0..<(idx.count / 3) {
                    let face = t < tf.count ? tf[t] : 0
                    for k in 0..<3 {
                        let vtx = Int(idx[t * 3 + k])
                        if vtx < n { faces[vtx] = face }
                    }
                }
            }
        }
        var lo = m.lo, hi = m.hi
        if lo.x > hi.x {
            lo = m.positions.reduce(SIMD3<Float>(repeating: .infinity)) { simd_min($0, $1) }
            hi = m.positions.reduce(SIMD3<Float>(repeating: -.infinity)) { simd_max($0, $1) }
        }
        return GPUMesh(positions: p, normals: nb, faces: f, indices: i, indexCount: m.indices.count, color: m.color, lo: lo, hi: hi)
    }

    private func segments(_ lines: [SceneData.Line], width: Float? = nil, color: SIMD4<Float>? = nil, onTop: Bool? = nil) -> (MTLBuffer?, Int) {
        var segs: [Segment] = []
        for l in lines where l.points.count > 1 {
            for i in 0..<(l.points.count - 1) {
                let a = l.points[i], b = l.points[i + 1]
                segs.append(Segment(a: (a.x, a.y, a.z), b: (b.x, b.y, b.z), color: color ?? l.color, width: width ?? l.width, onTop: (onTop ?? l.onTop) ? 1 : 0))
            }
        }
        guard !segs.isEmpty else { return (nil, 0) }
        return (device.makeBuffer(bytes: segs, length: segs.count * MemoryLayout<Segment>.stride), segs.count)
    }

    private func rebuildOverlay() {
        var lines: [SceneData.Line] = []
        for (mi, list) in highlight.edges where mi < scene.meshes.count {
            for ei in list where ei < scene.meshes[mi].edges.count {
                lines.append(.init(points: scene.meshes[mi].edges[ei], color: theme.highlight, width: 3.2, onTop: false))
            }
        }
        if let h = highlight.hoverEdge, h.mesh < scene.meshes.count, h.edge < scene.meshes[h.mesh].edges.count {
            lines.append(.init(points: scene.meshes[h.mesh].edges[h.edge], color: theme.hover, width: 2.6, onTop: false))
        }
        (overlayBuffer, overlayCount) = segments(lines)
    }

    /// The cap quads for the current section: one per opaque body whose bounds the plane crosses,
    /// centred on the body and wide enough to cover its whole cut.
    private func rebuildCaps() {
        caps = []
        guard let plane = sectionPlane else { return }
        for (i, m) in meshes.enumerated() where m.color.w >= 0.999 {
            guard let quad = SectionClip.capQuad(plane: plane, lo: m.lo, hi: m.hi) else { continue }
            // Packed float3, as the shader reads it.
            let flat = quad.flatMap { [$0.x, $0.y, $0.z] }
            if let b = device.makeBuffer(bytes: flat, length: flat.count * MemoryLayout<Float>.stride) {
                caps.append((i, b))
            }
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { requestDraw() }

    private var drewOnce = false

    func draw(in view: MTKView) {
        let t0 = Perf.now()
        defer { Perf.frame(start: t0, end: Perf.now()) }
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        encode(enc, drawableSize: view.drawableSize)
        enc.endEncoding()
        cmd.present(drawable)
        if Perf.enabled {
            let phase = Perf.phase
            cmd.addCompletedHandler { c in Perf.gpu((c.gpuEndTime - c.gpuStartTime) * 1000, phase: phase) }
        }
        cmd.commit()
        if !drewOnce { drewOnce = true; Perf.milestone("first frame") }
        if !meshes.isEmpty { Perf.milestone("first frame with bodies") }
    }

    /// Draws one frame into an offscreen texture of `width` x `height` pixels and returns its
    /// BGRA bytes (row major, top row first): what the self tests look at. `nil` without Metal.
    func renderOffscreen(width: Int, height: Int) -> [UInt8]? {
        let samples = view?.sampleCount ?? 4
        func texture(_ format: MTLPixelFormat, msaa: Bool, usage: MTLTextureUsage, storage: MTLStorageMode) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            if msaa { d.textureType = .type2DMultisample; d.sampleCount = samples }
            d.usage = usage
            d.storageMode = storage
            return device.makeTexture(descriptor: d)
        }
        #if os(macOS)
        let readable: MTLStorageMode = .managed
        #else
        let readable: MTLStorageMode = .shared
        #endif
        guard let colour = texture(.bgra8Unorm, msaa: true, usage: .renderTarget, storage: .private),
              let resolved = texture(.bgra8Unorm, msaa: false, usage: [.renderTarget, .shaderRead], storage: readable),
              let depth = texture(Self.depthStencilFormat, msaa: true, usage: .renderTarget, storage: .private) else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = colour
        pass.colorAttachments[0].resolveTexture = resolved
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.colorAttachments[0].clearColor = theme.clearColor
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.stencilAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.stencilAttachment.texture = depth
        pass.stencilAttachment.clearStencil = 0
        pass.stencilAttachment.storeAction = .dontCare
        guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        let saved = pointSize
        pointSize = CGSize(width: width, height: height)
        encode(enc, drawableSize: CGSize(width: width, height: height))
        pointSize = saved
        enc.endEncoding()
        #if os(macOS)
        if let blit = cmd.makeBlitCommandEncoder() { blit.synchronize(resource: resolved); blit.endEncoding() }
        #endif
        cmd.commit()
        cmd.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            resolved.getBytes(raw.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return bytes
    }

    private func encode(_ enc: MTLRenderCommandEncoder, drawableSize px: CGSize) {
        let aspect = Double(px.width / max(px.height, 1))
        let viewM = camera.viewMatrix()
        let proj = camera.projectionMatrix(aspect: aspect, radius: radius)
        var frame = Frame(
            viewProj: proj * viewM, view: viewM,
            bgTop: theme.backgroundTop, bgBottom: theme.backgroundBottom,
            highlight: theme.highlight, hover: theme.hover,
            viewport: SIMD2(Float(px.width), Float(px.height)),
            pixelScale: Float(px.height / max(pointSize.height, 1)),
            edgeBias: camera.fov > 0 ? 0.0004 : 0.0015
        )
        if let plane = sectionPlane {
            frame.clipPlane = plane.equation
            frame.clipOn = 1
        }
        let clipOn = frame.clipOn

        enc.setRenderPipelineState(backgroundPipeline)
        enc.setDepthStencilState(depthOff)
        enc.setFragmentBytes(&frame, length: MemoryLayout<Frame>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // The grid is not part of the model: the section never cuts it.
        frame.clipOn = 0
        drawLines(enc, gridBuffer, gridCount, &frame, depth: depthOff)
        frame.clipOn = clipOn

        enc.setRenderPipelineState(meshPipeline)
        enc.setDepthStencilState(depthOn)
        enc.setCullMode(.none)
        enc.setVertexBytes(&frame, length: MemoryLayout<Frame>.stride, index: 3)
        enc.setFragmentBytes(&frame, length: MemoryLayout<Frame>.stride, index: 0)
        for (i, m) in meshes.enumerated() where m.color.w >= 0.999 { drawMesh(enc, m, index: i) }
        drawCaps(enc, &frame)

        drawLines(enc, lineBuffer, lineCount, &frame, depth: depthOn)
        drawLines(enc, overlayBuffer, overlayCount, &frame, depth: depthRead)

        // See-through bodies after everything opaque, without writing depth.
        enc.setRenderPipelineState(meshPipeline)
        enc.setDepthStencilState(depthRead)
        enc.setVertexBytes(&frame, length: MemoryLayout<Frame>.stride, index: 3)
        enc.setFragmentBytes(&frame, length: MemoryLayout<Frame>.stride, index: 0)
        for (i, m) in meshes.enumerated() where m.color.w < 0.999 { drawMesh(enc, m, index: i) }
    }

    /// The section caps, body by body: flip the stencil with the clipped body, then draw its
    /// quad where the count is odd (the plane is inside the body there), clearing it again.
    private func drawCaps(_ enc: MTLRenderCommandEncoder, _ frame: inout Frame) {
        guard frame.clipOn > 0.5, !caps.isEmpty else { return }
        var style = SIMD4<Float>(sectionHatch ? 1 : 0, 0, 0, 0)
        for cap in caps where cap.mesh < meshes.count {
            let m = meshes[cap.mesh]
            enc.setRenderPipelineState(clipMaskPipeline)
            enc.setDepthStencilState(stencilFlip)
            enc.setStencilReferenceValue(0)
            enc.setVertexBytes(&frame, length: MemoryLayout<Frame>.stride, index: 3)
            enc.setFragmentBytes(&frame, length: MemoryLayout<Frame>.stride, index: 0)
            enc.setVertexBuffer(m.positions, offset: 0, index: 0)
            enc.setVertexBuffer(m.normals, offset: 0, index: 1)
            enc.setVertexBuffer(m.faces, offset: 0, index: 2)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: m.indexCount, indexType: .uint32, indexBuffer: m.indices, indexBufferOffset: 0)

            enc.setRenderPipelineState(capPipeline)
            enc.setDepthStencilState(capDepth)
            var colour = m.color
            enc.setVertexBuffer(cap.corners, offset: 0, index: 0)
            enc.setVertexBytes(&frame, length: MemoryLayout<Frame>.stride, index: 1)
            enc.setFragmentBytes(&frame, length: MemoryLayout<Frame>.stride, index: 0)
            enc.setFragmentBytes(&colour, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
            enc.setFragmentBytes(&style, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }

    private func drawMesh(_ enc: MTLRenderCommandEncoder, _ m: GPUMesh, index: Int) {
        var u = MeshUniform(color: m.color)
        let faces = highlight.faces[index] ?? []
        withUnsafeMutableBytes(of: &u.selected) { raw in
            let p = raw.bindMemory(to: Int32.self)
            for (k, f) in faces.prefix(16).enumerated() { p[k] = Int32(f) }
        }
        u.selectedCount = Int32(min(faces.count, 16))
        if let h = highlight.hoverFace, h.mesh == index { u.hovered = Int32(h.face) }
        u.bodySelected = highlight.bodies.contains(index) ? 1 : 0
        enc.setVertexBuffer(m.positions, offset: 0, index: 0)
        enc.setVertexBuffer(m.normals, offset: 0, index: 1)
        enc.setVertexBuffer(m.faces, offset: 0, index: 2)
        enc.setFragmentBytes(&u, length: MemoryLayout<MeshUniform>.stride, index: 1)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: m.indexCount, indexType: .uint32, indexBuffer: m.indices, indexBufferOffset: 0)
    }

    private func drawLines(_ enc: MTLRenderCommandEncoder, _ buf: MTLBuffer?, _ count: Int, _ frame: inout Frame, depth: MTLDepthStencilState) {
        guard let buf, count > 0 else { return }
        enc.setRenderPipelineState(linePipeline)
        enc.setDepthStencilState(depth)
        enc.setVertexBuffer(buf, offset: 0, index: 0)
        enc.setVertexBytes(&frame, length: MemoryLayout<Frame>.stride, index: 1)
        enc.setFragmentBytes(&frame, length: MemoryLayout<Frame>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: count)
    }
}
