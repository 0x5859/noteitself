#include <metal_stdlib>
using namespace metal;

// All geometry is given in page coordinates and mapped to pixels with
// `pixel = page * scale + offset`. Anti-aliasing is analytic (signed distance
// in pixels), so no MSAA buffers are needed.

struct Uniforms {
    float2 offset;      // pixels
    float2 viewport;    // pixels
    float  scale;       // pixels per page unit
    float  opacity;
    float  grainScale;  // grain texture repeats per page unit
    uint   flags;
};

static inline float4 clip_position(float2 px, float2 viewport) {
    return float4(px.x / viewport.x * 2.0 - 1.0, 1.0 - px.y / viewport.y * 2.0, 0.0, 1.0);
}

// MARK: - Capsule segments (pen, brush, marker, highlighter)

struct CapsuleInstance {
    float2 p0;
    float2 p1;
    float  r0;
    float  r1;
    uint   color;
    uint   key;      // 24-bit stroke id, never 0
};

struct CapsuleOut {
    float4 position [[position]];
    float2 px;
    float2 a [[flat]];
    float2 b [[flat]];
    float2 radii [[flat]];
    float4 color [[flat]];   // premultiplied
    uint   key [[flat]];
};

vertex CapsuleOut capsule_vertex(uint vid [[vertex_id]],
                                 uint iid [[instance_id]],
                                 const device CapsuleInstance *instances [[buffer(0)]],
                                 constant Uniforms &u [[buffer(1)]]) {
    CapsuleInstance in = instances[iid];
    float2 a = in.p0 * u.scale + u.offset;
    float2 b = in.p1 * u.scale + u.offset;
    float ra = in.r0 * u.scale;
    float rb = in.r1 * u.scale;

    // Hairlines: never go below about half a pixel of radius; fade instead,
    // which keeps thin strokes stable when zoomed out.
    float thin = clamp(max(ra, rb) / 0.55, 0.0001, 1.0);
    ra /= thin;
    rb /= thin;

    float2 d = b - a;
    float len = length(d);
    float2 dir = len > 1e-5 ? d / len : float2(1.0, 0.0);
    float2 nrm = float2(-dir.y, dir.x);
    float reach = max(ra, rb) + 1.0;

    float along = (vid & 1) ? 1.0 : -1.0;
    float side = (vid & 2) ? 1.0 : -1.0;
    float2 px = ((vid & 1) ? b : a) + dir * (along * reach) + nrm * (side * reach);

    float4 c = unpack_unorm4x8_to_float(in.color);
    float alpha = c.a * u.opacity * thin;

    CapsuleOut out;
    out.position = clip_position(px, u.viewport);
    out.px = px;
    out.a = a;
    out.b = b;
    out.radii = float2(ra, rb);
    out.color = float4(c.rgb * alpha, alpha);
    out.key = in.key & 0xFFFFFF;
    return out;
}

// Signed distance to a capsule with a different radius at each end.
// Adapted from Inigo Quilez's "Uneven Capsule" (MIT License; see
// THIRD_PARTY_NOTICES.md), with a guard for degenerate segments.
static float sd_uneven_capsule(float2 p, float2 pa, float2 pb, float ra, float rb) {
    float2 ba = pb - pa;
    float h = dot(ba, ba);
    float b = ra - rb;
    if (h <= b * b + 1e-6) {
        // One end swallows the other, or the segment is a dot.
        return min(length(p - pa) - ra, length(p - pb) - rb);
    }
    p -= pa;
    float2 q = float2(dot(p, float2(ba.y, -ba.x)), dot(p, ba)) / h;
    q.x = abs(q.x);
    float2 c = float2(sqrt(h - b * b), b);
    float k = c.x * q.y - c.y * q.x;
    float m = dot(c, q);
    float n = dot(q, q);
    if (k < 0.0) return sqrt(h * n) - ra;
    if (k > c.x) return sqrt(h * (n + 1.0 - 2.0 * q.y)) - rb;
    return m - ra;
}

// A stroke is many overlapping capsules. Blending each one "over" the page
// would count the anti-aliased fringe twice wherever two segments meet and
// leave a bead at every joint. Instead a second attachment remembers, per
// pixel, the coverage this stroke has already laid down there; a fragment only
// adds the difference. The result is the exact union of the segments, also
// for translucent ink. Reading the framebuffer costs nothing on Apple GPUs,
// and on device the mask lives purely in tile memory.
struct InkOut {
    float4 color [[color(0)]];
    float4 mask  [[color(1)]];
};

fragment InkOut capsule_fragment(CapsuleOut in [[stage_in]],
                                 float4 dst [[color(0)]],
                                 float4 mask [[color(1)]]) {
    float d = sd_uneven_capsule(in.px, in.a, in.b, in.radii.x, in.radii.y);
    float coverage = clamp(0.5 - d, 0.0, 1.0);

    uint3 stored = uint3(round(mask.gba * 255.0));
    uint owner = stored.x | (stored.y << 8) | (stored.z << 16);
    float previous = owner == in.key ? mask.r : 0.0;
    if (coverage <= previous + 0.002) discard_fragment();

    // With D0 the page before this stroke, the pixel must end up as
    // D0 * (1 - a*c) + S*c for coverage c. Going from `previous` to
    // `coverage` without knowing D0:
    float a = in.color.a;
    float3 ink = in.color.rgb;
    float keep = (1.0 - a * coverage) / max(1.0 - a * previous, 1e-4);

    InkOut out;
    out.color = float4((dst.rgb - ink * previous) * keep + ink * coverage, 1.0);
    out.mask = float4(coverage,
                      float(in.key & 0xFF) / 255.0,
                      float((in.key >> 8) & 0xFF) / 255.0,
                      float((in.key >> 16) & 0xFF) / 255.0);
    return out;
}

// Fallback for GPUs that cannot read the framebuffer (the iOS Simulator):
// plain "over" blending per segment. Joints are very slightly heavier.
fragment float4 capsule_fragment_plain(CapsuleOut in [[stage_in]]) {
    float d = sd_uneven_capsule(in.px, in.a, in.b, in.radii.x, in.radii.y);
    return in.color * clamp(0.5 - d, 0.0, 1.0);
}

// Highlighter: drawn with a MIN blend, so overlapping segments of one stroke
// never build up and dark ink underneath stays dark.
fragment float4 highlight_fragment(CapsuleOut in [[stage_in]]) {
    float d = sd_uneven_capsule(in.px, in.a, in.b, in.radii.x, in.radii.y);
    float coverage = clamp(0.5 - d, 0.0, 1.0) * in.color.a;
    float3 ink = in.color.a > 0.0 ? in.color.rgb / in.color.a : float3(1.0);
    return float4(mix(float3(1.0), ink, coverage), 1.0);
}

// MARK: - Stamps (pencil)

struct StampInstance {
    float2 center;
    float  radius;
    float  alpha;
    uint   color;
    uint   pad;
};

struct StampOut {
    float4 position [[position]];
    float2 uv;
    float2 page;
    float4 color [[flat]];
};

vertex StampOut stamp_vertex(uint vid [[vertex_id]],
                             uint iid [[instance_id]],
                             const device StampInstance *instances [[buffer(0)]],
                             constant Uniforms &u [[buffer(1)]]) {
    StampInstance in = instances[iid];
    float2 c = in.center * u.scale + u.offset;
    float r = in.radius * u.scale;
    float thin = clamp(r / 0.75, 0.0001, 1.0);
    r /= thin;
    float reach = r + 0.5;

    float2 corner = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
    float2 px = c + corner * reach;

    float4 col = unpack_unorm4x8_to_float(in.color);
    float alpha = col.a * in.alpha * u.opacity * thin;

    StampOut out;
    out.position = clip_position(px, u.viewport);
    out.uv = corner * (reach / r);
    out.page = (px - u.offset) / u.scale;
    out.color = float4(col.rgb * alpha, alpha);
    return out;
}

fragment float4 stamp_fragment(StampOut in [[stage_in]],
                               texture2d<float> grain [[texture(0)]],
                               sampler grainSampler [[sampler(0)]],
                               constant Uniforms &u [[buffer(1)]]) {
    float d = length(in.uv);
    float falloff = 1.0 - smoothstep(0.45, 1.0, d);
    // The grain is anchored to the page, like paper tooth catching graphite.
    float tooth = grain.sample(grainSampler, in.page * u.grainScale).r;
    return in.color * (falloff * mix(0.3, 1.0, tooth));
}

// MARK: - Paper

struct PaperUniforms {
    float4 rect;     // x, y, w, h in page units
    float4 paper;
    float4 line;
    float  spacing;  // page units
    float  style;    // 0 blank, 1 lined, 2 grid, 3 dots
    float  inset;    // top margin for ruled paper
    float  pad;
};

struct PaperOut {
    float4 position [[position]];
    float2 page;
};

vertex PaperOut paper_vertex(uint vid [[vertex_id]],
                             constant Uniforms &u [[buffer(1)]],
                             constant PaperUniforms &p [[buffer(2)]]) {
    float2 unit = float2((vid & 1) ? 1.0 : 0.0, (vid & 2) ? 1.0 : 0.0);
    float2 page = p.rect.xy + unit * p.rect.zw;
    PaperOut out;
    out.position = clip_position(page * u.scale + u.offset, u.viewport);
    out.page = page;
    return out;
}

fragment float4 paper_fragment(PaperOut in [[stage_in]],
                               constant Uniforms &u [[buffer(1)]],
                               constant PaperUniforms &p [[buffer(2)]]) {
    float3 color = p.paper.rgb;
    if (p.style < 0.5) return float4(color, 1.0);

    float cell = p.spacing * u.scale;                 // pixels between rules
    float fade = smoothstep(5.0, 11.0, cell) * p.line.a;
    float coverage = 0.0;

    if (p.style < 1.5) {
        float y = in.page.y - p.inset;
        float dist = abs(fract(y / p.spacing + 0.5) - 0.5) * cell;
        float half_width = clamp(0.35 * u.scale, 0.5, 1.5);
        coverage = y > -p.spacing * 0.5 ? clamp(half_width + 0.5 - dist, 0.0, 1.0) : 0.0;
    } else if (p.style < 2.5) {
        float2 dist = abs(fract(in.page / p.spacing + 0.5) - 0.5) * cell;
        float half_width = clamp(0.3 * u.scale, 0.5, 1.25);
        coverage = clamp(half_width + 0.5 - min(dist.x, dist.y), 0.0, 1.0);
    } else {
        float2 offset = (fract(in.page / p.spacing + 0.5) - 0.5) * cell;
        float radius = clamp(0.75 * u.scale, 1.0, 3.0);
        coverage = clamp(radius + 0.5 - length(offset), 0.0, 1.0);
    }
    return float4(mix(color, p.line.rgb, coverage * fade), 1.0);
}

// MARK: - Textured quads (PDF pages, images)

struct QuadUniforms {
    float4 rect;    // x, y, w, h in page units
    float  alpha;
    float  pad0;
    float  pad1;
    float  pad2;
};

struct QuadOut {
    float4 position [[position]];
    float2 uv;
};

vertex QuadOut quad_vertex(uint vid [[vertex_id]],
                           constant Uniforms &u [[buffer(1)]],
                           constant QuadUniforms &q [[buffer(2)]]) {
    float2 unit = float2((vid & 1) ? 1.0 : 0.0, (vid & 2) ? 1.0 : 0.0);
    QuadOut out;
    out.position = clip_position((q.rect.xy + unit * q.rect.zw) * u.scale + u.offset, u.viewport);
    out.uv = unit;
    return out;
}

fragment float4 quad_fragment(QuadOut in [[stage_in]],
                              texture2d<float> tex [[texture(0)]],
                              sampler texSampler [[sampler(0)]],
                              constant QuadUniforms &q [[buffer(2)]]) {
    return tex.sample(texSampler, in.uv) * q.alpha;   // texture is premultiplied
}

// MARK: - Blit

struct BlitOut {
    float4 position [[position]];
};

vertex BlitOut blit_vertex(uint vid [[vertex_id]]) {
    BlitOut out;
    out.position = float4(float((vid << 1) & 2) * 2.0 - 1.0, float(vid & 2) * 2.0 - 1.0, 0.0, 1.0);
    return out;
}

fragment float4 blit_fragment(BlitOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
    return tex.read(uint2(in.position.xy));
}
