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
}

/// Draws the engine's scene with Metal: background, grid, bodies, edges and sketch lines.
final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private var meshPipeline: MTLRenderPipelineState!
    private var linePipeline: MTLRenderPipelineState!
    private var backgroundPipeline: MTLRenderPipelineState!
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

    var camera = OrbitCamera()
    var radius: Double = 100
    var theme: ViewportTheme
    var highlight = Highlight()
    var pointSize: CGSize = .init(width: 1, height: 1)
    private var scene = SceneData()

    init?(view: MTKView, theme: ViewportTheme) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.theme = theme
        super.init()
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = 4
        view.clearColor = MTLClearColor(red: 0.9, green: 0.9, blue: 0.92, alpha: 1)
        guard buildPipelines(view) else { return nil }
    }

    private func buildPipelines(_ view: MTKView) -> Bool {
        guard let lib = device.makeDefaultLibrary() else { return false }
        func pipeline(_ v: String, _ f: String, blend: Bool, depth: Bool = true) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: v)
            d.fragmentFunction = lib.makeFunction(name: f)
            d.colorAttachments[0].pixelFormat = view.colorPixelFormat
            d.depthAttachmentPixelFormat = view.depthStencilPixelFormat
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
        func depth(_ compare: MTLCompareFunction, write: Bool) -> MTLDepthStencilState? {
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = compare
            d.isDepthWriteEnabled = write
            return device.makeDepthStencilState(descriptor: d)
        }
        depthOn = depth(.lessEqual, write: true)
        depthRead = depth(.lessEqual, write: false)
        depthOff = depth(.always, write: false)
        return meshPipeline != nil && linePipeline != nil && backgroundPipeline != nil
    }

    /// Takes a new scene from the engine.
    func update(scene: SceneData) {
        self.scene = scene
        radius = Double(scene.radius)
        meshes = scene.meshes.compactMap(upload)
        (lineBuffer, lineCount) = segments(scene.lines)
        let grid = theme.gridOpacity == 1 ? scene.grid : scene.grid.map { l in
            var l = l
            l.color.w *= theme.gridOpacity
            return l
        }
        (gridBuffer, gridCount) = segments(grid)
        rebuildOverlay()
    }

    func setHighlight(_ h: Highlight) {
        guard h != highlight else { return }
        highlight = h
        rebuildOverlay()
    }

    private func upload(_ m: SceneData.Mesh) -> GPUMesh? {
        guard !m.positions.isEmpty, !m.indices.isEmpty else { return nil }
        var faces = [UInt32](repeating: 0, count: m.positions.count)
        for t in 0..<(m.indices.count / 3) {
            let f = t < m.triFace.count ? m.triFace[t] : 0
            for k in 0..<3 { faces[Int(m.indices[t * 3 + k])] = f }
        }
        let pos = m.positions.flatMap { [$0.x, $0.y, $0.z] }
        let nrm = m.normals.count == m.positions.count ? m.normals.flatMap { [$0.x, $0.y, $0.z] } : [Float](repeating: 0, count: pos.count)
        guard let p = device.makeBuffer(bytes: pos, length: pos.count * 4),
              let n = device.makeBuffer(bytes: nrm, length: nrm.count * 4),
              let f = device.makeBuffer(bytes: faces, length: faces.count * 4),
              let i = device.makeBuffer(bytes: m.indices, length: m.indices.count * 4) else { return nil }
        return GPUMesh(positions: p, normals: n, faces: f, indices: i, indexCount: m.indices.count, color: m.color)
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

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        let px = view.drawableSize
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

        enc.setRenderPipelineState(backgroundPipeline)
        enc.setDepthStencilState(depthOff)
        enc.setFragmentBytes(&frame, length: MemoryLayout<Frame>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        drawLines(enc, gridBuffer, gridCount, &frame, depth: depthOff)

        enc.setRenderPipelineState(meshPipeline)
        enc.setDepthStencilState(depthOn)
        enc.setCullMode(.none)
        enc.setVertexBytes(&frame, length: MemoryLayout<Frame>.stride, index: 3)
        enc.setFragmentBytes(&frame, length: MemoryLayout<Frame>.stride, index: 0)
        for (i, m) in meshes.enumerated() where m.color.w >= 0.999 { drawMesh(enc, m, index: i) }

        drawLines(enc, lineBuffer, lineCount, &frame, depth: depthOn)
        drawLines(enc, overlayBuffer, overlayCount, &frame, depth: depthRead)

        // See-through bodies after everything opaque, without writing depth.
        enc.setRenderPipelineState(meshPipeline)
        enc.setDepthStencilState(depthRead)
        enc.setVertexBytes(&frame, length: MemoryLayout<Frame>.stride, index: 3)
        enc.setFragmentBytes(&frame, length: MemoryLayout<Frame>.stride, index: 0)
        for (i, m) in meshes.enumerated() where m.color.w < 0.999 { drawMesh(enc, m, index: i) }

        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
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
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: count)
    }
}
