#include <metal_stdlib>
using namespace metal;

struct Frame {
    float4x4 viewProj;
    float4x4 view;
    float4 bgTop;
    float4 bgBottom;
    float4 highlight;
    float4 hover;
    float2 viewport;   // drawable pixels
    float pixelScale;  // drawable pixels per point
    float edgeBias;    // clip-space depth pulled toward the eye for edges
};

struct MeshUniform {
    float4 color;
    int selected[16];
    int selectedCount;
    int hovered;
    int bodySelected;
    int pad;
};

struct MeshOut {
    float4 position [[position]];
    float3 normal;
    float3 viewPos;
    uint face [[flat]];
};

vertex MeshOut mesh_vertex(uint vid [[vertex_id]],
                           const device packed_float3 *positions [[buffer(0)]],
                           const device packed_float3 *normals [[buffer(1)]],
                           const device uint *faces [[buffer(2)]],
                           constant Frame &frame [[buffer(3)]]) {
    MeshOut o;
    float3 p = positions[vid];
    o.position = frame.viewProj * float4(p, 1);
    o.normal = (frame.view * float4(float3(normals[vid]), 0)).xyz;
    o.viewPos = (frame.view * float4(p, 1)).xyz;
    o.face = faces[vid];
    return o;
}

fragment float4 mesh_fragment(MeshOut in [[stage_in]], bool front [[front_facing]],
                              constant Frame &frame [[buffer(0)]],
                              constant MeshUniform &u [[buffer(1)]]) {
    float3 n = normalize(in.normal);
    if (!front) n = -n;
    float3 v = normalize(-in.viewPos);
    if (dot(n, v) < 0) n = -n;
    // Studio light: a key from the upper left, a soft fill and a sky/ground hemisphere.
    float3 key = normalize(float3(-0.45, 0.65, 0.65));
    float3 fill = normalize(float3(0.6, -0.2, 0.75));
    float diff = max(dot(n, key), 0.0) * 0.62 + max(dot(n, fill), 0.0) * 0.22;
    float hemi = mix(0.30, 0.42, n.y * 0.5 + 0.5);
    float3 h = normalize(key + v);
    float spec = pow(max(dot(n, h), 0.0), 48.0) * 0.18;
    float3 base = u.color.rgb;
    bool sel = u.bodySelected != 0;
    for (int i = 0; i < u.selectedCount; i++) { if (u.selected[i] == int(in.face)) sel = true; }
    if (sel) base = mix(base, frame.highlight.rgb, 0.55);
    else if (u.hovered == int(in.face)) base = mix(base, frame.hover.rgb, 0.35);
    float3 c = base * (diff + hemi) + spec;
    return float4(c, u.color.a);
}

struct Segment {
    packed_float3 a;
    packed_float3 b;
    float4 color;
    float width;  // points
    float onTop;
};

struct LineOut {
    float4 position [[position]];
    float4 color;
};

vertex LineOut line_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                           const device Segment *segs [[buffer(0)]],
                           constant Frame &frame [[buffer(1)]]) {
    Segment s = segs[iid];
    float4 a = frame.viewProj * float4(float3(s.a), 1);
    float4 b = frame.viewProj * float4(float3(s.b), 1);
    // Clip a perspective segment that crosses behind the eye at the near side.
    float2 sa = a.xy / max(a.w, 1e-5), sb = b.xy / max(b.w, 1e-5);
    float2 dir = (sb - sa) * frame.viewport;
    float len = length(dir);
    dir = len > 1e-6 ? dir / len : float2(1, 0);
    float2 nrm = float2(-dir.y, dir.x);
    float half_w = max(s.width * frame.pixelScale, 1.0) * 0.5 + 0.5;
    const float2 corners[6] = { float2(0, -1), float2(1, -1), float2(1, 1), float2(0, -1), float2(1, 1), float2(0, 1) };
    float2 c = corners[vid];
    float4 p = mix(a, b, c.x);
    float2 offset = nrm * c.y * half_w / frame.viewport * 2.0 * p.w;
    p.xy += offset;
    p.z -= frame.edgeBias * p.w;
    if (s.onTop > 0.5) p.z = 0.0;
    LineOut o;
    o.position = p;
    o.color = s.color;
    return o;
}

fragment float4 line_fragment(LineOut in [[stage_in]]) { return in.color; }

struct BgOut {
    float4 position [[position]];
    float t;
};

vertex BgOut background_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2) * 2.0 - 1.0;
    BgOut o;
    o.position = float4(p, 1, 1);
    o.t = p.y * 0.5 + 0.5;
    return o;
}

fragment float4 background_fragment(BgOut in [[stage_in]], constant Frame &frame [[buffer(0)]]) {
    return mix(frame.bgBottom, frame.bgTop, saturate(in.t));
}
