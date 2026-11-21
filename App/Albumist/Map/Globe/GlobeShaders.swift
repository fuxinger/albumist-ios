import Foundation

/// The Metal shaders of our own globe (concept §7, plan A), as source that `GlobeRenderer` compiles
/// when the globe first appears (`MTLDevice.makeLibrary(source:options:completionHandler:)`, timed
/// as `MetricEvent.shaderCompile`). The prototype has no .metal files, so the app's build settings
/// stay as they are.
///
/// Four draws per frame, in this order:
/// - the stars: points far away (the camera's turn only), faint and few on screen;
/// - the Earth: the NASA image on the unit sphere, gently shaded from the upper left, the visited
///   countries a little brighter (the mask of `CountryMask`), a blue rim of air at the edge;
/// - the halo: the atmosphere's glow beyond the edge, on a square through the Earth's centre
///   facing the camera (the Earth's depth hides the part over the disc);
/// - the arcs: ribbons widened on screen round their curve (`GlobeArcMesh`), a crisp core and a
///   soft glow from warm white at home to sun-gold at the destination, behind the Earth hidden
///   by its depth, blended like light ("screen") so that many arcs meeting at home stay soft
///   instead of burning out to white.
///
/// The layouts below must match the Swift side exactly: `GlobeUniforms` the 56 floats of
/// `GlobeRenderer.uniformValues`, `SphereVertex` the 5 floats of `GlobeMesh.sphere`, `StarVertex`
/// the 4 of `GlobeMesh.stars`, `ArcVertex` the 14 of `GlobeArcMesh` (packed vectors, every field
/// 4-byte aligned, no padding). Colours are linear: the drawable is sRGB.
enum GlobeShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct GlobeUniforms {
        float4x4 viewProjection;   // the globe's space to clip space
        float4x4 sky;              // directions to clip space: the camera's turn only
        float4 eye;                // xyz: the eye; w: how far the globe has faded in (0 to 1)
        float4 right;              // xyz: the camera's right; w: half the side of the halo's square
        float4 up;                 // xyz: the camera's up; w: the halo's outer radius
        float4 light;              // xyz: towards the light; w: the tint's strength (0 to 1)
        float4 viewport;           // xy: the drawable in pixels; z: pixels per point; w: seconds the arcs have grown
        float4 arcs;               // x: core half width (px); y: glow radius (px); z: ribbon half width (px); w: opacity
    };

    constant float3 airColor = float3(0.30, 0.56, 1.0);
    constant float3 warmWhite = float3(1.0, 0.904, 0.672);   // #FFF4D6
    constant float3 sunGold = float3(1.0, 0.584, 0.074);     // #FFC94D

    // MARK: Stars

    struct StarVertex {
        packed_float3 direction;
        float brightness;
    };

    struct StarOut {
        float4 position [[position]];
        float pointSize [[point_size]];
        float brightness;
    };

    vertex StarOut starVertex(uint vid [[vertex_id]],
                              const device StarVertex *stars [[buffer(0)]],
                              constant GlobeUniforms &u [[buffer(1)]]) {
        StarVertex star = stars[vid];
        float4 p = u.sky * float4(float3(star.direction), 0.0);
        p.z = 0.5 * p.w;
        StarOut out;
        out.position = p;
        out.pointSize = (1.3 + 1.9 * star.brightness) * u.viewport.z * 0.6;
        out.brightness = star.brightness * u.eye.w;
        return out;
    }

    fragment float4 starFragment(StarOut in [[stage_in]],
                                 float2 pointCoord [[point_coord]]) {
        float r = length(pointCoord - float2(0.5)) * 2.0;
        float a = saturate(1.0 - r);
        float3 color = float3(0.80, 0.87, 1.0) * (in.brightness * a * a);
        return float4(color, 1.0);
    }

    // MARK: Earth

    struct SphereVertex {
        packed_float3 position;
        packed_float2 uv;
    };

    struct EarthOut {
        float4 position [[position]];
        float3 normal;
        float2 uv;
    };

    vertex EarthOut earthVertex(uint vid [[vertex_id]],
                                const device SphereVertex *vertices [[buffer(0)]],
                                constant GlobeUniforms &u [[buffer(1)]]) {
        SphereVertex v = vertices[vid];
        float3 p = float3(v.position);
        EarthOut out;
        out.position = u.viewProjection * float4(p, 1.0);
        out.normal = p;
        out.uv = float2(v.uv);
        return out;
    }

    fragment float4 earthFragment(EarthOut in [[stage_in]],
                                  constant GlobeUniforms &u [[buffer(0)]],
                                  texture2d<float> earthImage [[texture(0)]],
                                  texture2d<float> visitedMask [[texture(1)]],
                                  sampler imageSampler [[sampler(0)]]) {
        float3 n = normalize(in.normal);
        float3 color = earthImage.sample(imageSampler, in.uv).rgb;
        // Visited countries: a little brighter and warmer.
        float tint = visitedMask.sample(imageSampler, in.uv).r * u.light.w;
        color = color * (1.0 + 0.6 * tint) + float3(0.045, 0.036, 0.018) * tint;
        // Gentle light from the upper left, never dark.
        float diffuse = saturate(dot(n, u.light.xyz));
        color *= 0.62 + 0.53 * diffuse;
        // The air at the edge of the disc.
        float3 toEye = normalize(u.eye.xyz - n);
        float facing = saturate(dot(n, toEye));
        float edge = 1.0 - facing;
        float rim = edge * edge * edge;
        color = mix(color, airColor, rim * 0.45);
        return float4(color * u.eye.w, 1.0);
    }

    // MARK: Halo

    struct HaloOut {
        float4 position [[position]];
        float3 world;
    };

    vertex HaloOut haloVertex(uint vid [[vertex_id]],
                              constant GlobeUniforms &u [[buffer(1)]]) {
        float x = (vid & 1u) != 0u ? 1.0 : -1.0;
        float y = (vid & 2u) != 0u ? 1.0 : -1.0;
        float3 p = (u.right.xyz * x + u.up.xyz * y) * u.right.w;
        HaloOut out;
        out.position = u.viewProjection * float4(p, 1.0);
        out.world = p;
        return out;
    }

    fragment float4 haloFragment(HaloOut in [[stage_in]],
                                 constant GlobeUniforms &u [[buffer(0)]]) {
        float3 eye = u.eye.xyz;
        float3 direction = normalize(in.world - eye);
        // How close the ray from the eye passes the Earth's centre, in Earth radii.
        float along = -dot(eye, direction);
        float h = length(eye + direction * along);
        float above = max(h - 1.0, 0.0);
        float glow = exp(-above / 0.028) * 0.7 + exp(-above / 0.08) * 0.1;
        glow *= 1.0 - smoothstep(u.up.w - 0.12, u.up.w, h);
        return float4(airColor * (glow * u.eye.w), 1.0);
    }

    // MARK: Arcs

    struct ArcVertex {
        packed_float3 position;
        packed_float3 previous;
        packed_float3 next;
        float side;
        float t;
        float strength;
        float phase;
        float distance;
    };

    struct ArcOut {
        float4 position [[position]];
        float across;     // pixels from the curve, signed
        float t;          // 0 at home, 1 at the destination
        float strength;
        float grown;      // how much of the arc is drawn (0 to 1)
    };

    vertex ArcOut arcVertex(uint vid [[vertex_id]],
                            const device ArcVertex *vertices [[buffer(0)]],
                            constant GlobeUniforms &u [[buffer(1)]]) {
        ArcVertex v = vertices[vid];
        float4 clip = u.viewProjection * float4(float3(v.position), 1.0);
        float4 clipPrevious = u.viewProjection * float4(float3(v.previous), 1.0);
        float4 clipNext = u.viewProjection * float4(float3(v.next), 1.0);
        float2 halfSize = u.viewport.xy * 0.5;
        float2 previous = clipPrevious.xy / clipPrevious.w * halfSize;
        float2 next = clipNext.xy / clipNext.w * halfSize;
        float2 direction = next - previous;
        float span = length(direction);
        direction = span > 0.00001 ? direction / span : float2(1.0, 0.0);
        float2 across = float2(-direction.y, direction.x);
        float halfWidth = u.arcs.z * (0.8 + 0.2 * v.strength);
        clip.xy += across * (v.side * halfWidth) / halfSize * clip.w;
        // A little towards the eye, so that the ends on the ground are not cut by the Earth.
        clip.z -= 0.0006 * clip.w;
        ArcOut out;
        out.position = clip;
        out.across = v.side * halfWidth;
        out.t = v.t;
        out.strength = v.strength;
        // Each arc grows from home in 1.4 s, the arcs one after the other within 0.9 s.
        out.grown = saturate((u.viewport.w - v.phase * 0.9) / 1.4);
        return out;
    }

    fragment float4 arcFragment(ArcOut in [[stage_in]],
                                constant GlobeUniforms &u [[buffer(0)]]) {
        if (in.t > in.grown) {
            discard_fragment();
        }
        float d = abs(in.across);
        float coreWidth = u.arcs.x * (0.75 + 0.25 * in.strength);
        float core = 1.0 - smoothstep(coreWidth - 0.7, coreWidth + 0.7, d);
        float sigma = u.arcs.y * (0.8 + 0.2 * in.strength);
        float glow = exp(-0.5 * d * d / (sigma * sigma));
        // Faint where all arcs meet at home, full from a third of the way on.
        float away = smoothstep(0.0, 0.3, in.t);
        // The growing tip shines brighter.
        float k = (in.grown - in.t) * 14.0;
        float tip = in.grown < 1.0 ? exp(-k * k) : 0.0;
        float intensity = core * (0.6 + 0.15 * in.strength) * (0.4 + 0.6 * away)
            + glow * ((0.12 + 0.06 * in.strength) * (0.2 + 0.8 * away) + 0.7 * tip);
        float3 color = mix(warmWhite, sunGold, smoothstep(0.0, 1.0, in.t)) * (intensity * u.arcs.w);
        return float4(min(color, float3(1.0)), 0.0);
    }
    """
}
