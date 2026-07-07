//  SwirlCore.metal
//  Canonical neon liquid-marble effect (Apple Pro Display XDR "swirl" look).
//
//  The whole image is produced by one screen-space function, swirl_color():
//    1. domain-warped fBm  -> flowing marble field  (the liquid ribbons)
//    2. iso-contour lines of that field             (the thin bright bands)
//    3. per-channel offset + cosine palette         (the oil-on-water rainbow)
//    4. gradient gating                             (black between ribbon clusters)
//
//  This file is shared verbatim by the screensaver fragment shader and by the
//  offline preview harness, so the on-screen look matches the stills exactly.

#include <metal_stdlib>
using namespace metal;

struct SwirlUniforms {
    float2 res;         // pixel resolution
    float  time;        // seconds
    float  speed;       // flow speed multiplier
    float  density;     // pattern scale (higher = finer marble)
    float  warp;        // domain-warp strength (higher = more turbulent pull)
    float  chroma;      // chromatic separation (oil-slick fringing)
    float  hueShift;    // palette phase
    float  brightness;  // overall gain
    float  saturation;  // 0 = grayscale, 1 = full neon
    float  lineDensity; // iso-contours per field unit (ribbon line count)
    float  paletteScale;// hue cycles across the field
};

// --- value noise ------------------------------------------------------------
static inline float hash21(float2 p) {
    p = fract(p * float2(123.34, 345.45));
    p += dot(p, p + 34.345);
    return fract(p.x * p.y);
}

static inline float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1, 0));
    float c = hash21(i + float2(0, 1));
    float d = hash21(i + float2(1, 1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

static inline float fbm(float2 p) {
    // Three octaves, fast amplitude falloff -> smooth, low-frequency field so the
    // ribbons read as big sweeping liquid (also cheaper than four octaves).
    float v = 0.0, a = 0.60;
    float2x2 m = float2x2(1.6, 1.2, -1.2, 1.6);
    for (int i = 0; i < 3; i++) { v += a * vnoise(p); p = m * p; a *= 0.42; }
    return v;
}

// Exact reference palette (8 neon stops on black), ordered around the hue wheel
// so the field flows smoothly through them and wraps. sRGB hex written directly
// to the non-sRGB drawable so on-screen color matches the hex swatches.
//   red #FF0305 · amber #FFB60A · gold #F9D914 · cyan #21FBFE
//   blue #0955FE · blue-violet #851CEA · neon-violet #D501FF · rose #FE09C9
static inline float3 palette(float t) {
    float3 c0 = float3(1.000, 0.012, 0.020);  // red        #FF0305
    float3 c1 = float3(1.000, 0.714, 0.039);  // amber      #FFB60A
    float3 c2 = float3(0.976, 0.851, 0.078);  // gold       #F9D914
    float3 c3 = float3(0.129, 0.984, 0.996);  // cyan       #21FBFE
    float3 c4 = float3(0.035, 0.333, 0.996);  // blue       #0955FE
    float3 c5 = float3(0.522, 0.110, 0.918);  // blue-violet#851CEA
    float3 c6 = float3(0.835, 0.004, 1.000);  // neon-violet#D501FF
    float3 c7 = float3(0.996, 0.035, 0.788);  // rose       #FE09C9

    t = fract(t);
    float x = t * 8.0;
    int i = int(floor(x)) % 8;
    float f = smoothstep(0.0, 1.0, x - floor(x));

    float3 stops[8] = { c0, c1, c2, c3, c4, c5, c6, c7 };
    return mix(stops[i], stops[(i + 1) % 8], f);
}

// The warped marble field, evaluated at a screen-space pixel coordinate.
static inline float swirl_field(float2 frag, constant SwirlUniforms& u) {
    float2 uv = (frag - 0.5 * u.res) / u.res.y;
    float2 p  = uv * u.density;
    float  t  = u.time * u.speed;

    float2 q = float2(fbm(p + float2(0.0, 0.0) + 0.10 * t),
                      fbm(p + float2(5.2, 1.3) - 0.11 * t));
    float2 r = float2(fbm(p + u.warp * q + float2(1.7, 9.2) + 0.13 * t),
                      fbm(p + u.warp * q + float2(8.3, 2.8) - 0.09 * t));
    return fbm(p + u.warp * r);
}

// Smooth ribbon band: a bright lobe that falls off to dark gaps between bands.
// `sharp` controls how tight the band is (higher = thinner, glossier ribbon).
static inline float band(float phase, float sharp) {
    float s = 0.5 + 0.5 * cos(6.28318530718 * phase);
    return pow(s, sharp);
}

// Main entry: final color for a pixel.
static inline float3 swirl_color(float2 frag, constant SwirlUniforms& u) {
    float f0 = swirl_field(frag, u);

    float bd = u.lineDensity;                 // bands per field unit
    float phase = f0 * bd;

    // Soft, wide bands -> gentle flowing ribbons (low sharp = smooth edges, so
    // the field reads as liquid rather than hard neon filaments).
    float off = u.chroma;
    float sharp = 2.4;
    float3 bands = float3(band(phase + off, sharp),
                          band(phase,       sharp),
                          band(phase - off, sharp));

    // Smooth rainbow following the flow.
    float3 col = palette(f0 * u.paletteScale + u.hueShift);

    // Gentle specular sheen along ribbon crests (soft, not a hard white line).
    float crest = pow(bands.g, 3.0);

    col = col * bands;
    col += crest * float3(0.9, 0.95, 1.0) * 0.25;

    // Saturation + gain, then a soft filmic knee so bright cores bloom to white.
    float luma = dot(col, float3(0.299, 0.587, 0.114));
    col = mix(float3(luma), col, u.saturation);
    col *= u.brightness;
    col = col / (1.0 + col * 0.5);            // gentle tone-map, keeps neon punch
    return max(col, 0.0);
}

// --- screensaver entry points ----------------------------------------------
// Full-screen triangle; no vertex buffer needed. The preview harness ignores
// these (it appends its own compute kernel) so this file stays the single
// source of truth for the look.
struct VSOut { float4 pos [[position]]; };

vertex VSOut swirl_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);   // (0,0) (2,0) (0,2)
    VSOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

fragment float4 swirl_fragment(VSOut in [[stage_in]],
                               constant SwirlUniforms& u [[buffer(0)]]) {
    return float4(swirl_color(in.pos.xy, u), 1.0);
}

// ===========================================================================
//  Variant 2: "Liquid Glass"
//  Direct port of paper.design's liquidGlass.metal — iridescent refractive
//  glass with Simplex-noise edge distortion, Fresnel bulge, per-channel
//  chromatic refraction and film grain. Math kept identical to the source.
// ===========================================================================

constant float PI  = 3.14159265359;
constant float TAU = 6.28318530718;

static inline float liquid_rectDistance(float2 p, float2 sz, float radius, float ratio) {
    p.x *= ratio; sz.x *= ratio;
    float2 q = abs(p) - sz + float2(radius);
    return min(max(q.x, q.y), 0.0) + length(max(q, float2(0.0))) - radius;
}
static inline float2 liquid_rotate(float2 uv, float th) {
    float s = sin(th), c = cos(th);
    return float2x2(c, s, -s, c) * uv;
}
static inline float3 liquid_mod289_3(float3 x){return x-floor(x*(1.0/289.0))*289.0;}
static inline float2 liquid_mod289_2(float2 x){return x-floor(x*(1.0/289.0))*289.0;}
static inline float3 liquid_permute(float3 x){return liquid_mod289_3(((x*34.0)+1.0)*x);}
static inline float liquid_snoise(float2 v){
    const float4 C=float4(0.211324865405187,0.366025403784439,-0.577350269189626,0.024390243902439);
    float2 i=floor(v+dot(v,C.yy));
    float2 x0=v-i+dot(i,C.xx);
    float2 i1=(x0.x>x0.y)?float2(1.0,0.0):float2(0.0,1.0);
    float4 x12=x0.xyxy+C.xxzz; x12.xy-=i1;
    i=liquid_mod289_2(i);
    float3 p=liquid_permute(liquid_permute(i.y+float3(0.0,i1.y,1.0))+i.x+float3(0.0,i1.x,1.0));
    float3 m=max(0.5-float3(dot(x0,x0),dot(x12.xy,x12.xy),dot(x12.zw,x12.zw)),0.0);
    m=m*m; m=m*m;
    float3 xx=2.0*fract(p*C.www)-1.0;
    float3 h=abs(xx)-0.5;
    float3 ox=floor(xx+0.5);
    float3 a0=xx-ox;
    m*=1.79284291400159-0.85373472095314*(a0*a0+h*h);
    float3 g;
    g.x=a0.x*x0.x+h.x*x0.y;
    g.yz=a0.yz*x12.xz+h.yz*x12.yw;
    return 130.0*dot(m,g);
}
static inline float liquid_mod_glsl(float x,float y){return x-y*floor(x/y);}
static inline float liquid_gauss(float z,float u,float o){return (1.0/(o*sqrt(2.0*PI)))*exp(-(((z-u)*(z-u))/(2.0*(o*o))));}
static inline float liquid_get_channel(float c1,float c2,float stripe_p,float3 w,float extra_blur,float b,float patternBlur){
    float ch=c2; float blur=patternBlur+extra_blur;
    ch=mix(ch,c1,smoothstep(0.0,blur,stripe_p));
    float border=w[0];
    ch=mix(ch,c2,smoothstep(border-blur,border+blur,stripe_p));
    b=smoothstep(0.2,0.8,b);
    border=w[0]+0.4*(1.0-b)*w[1];
    ch=mix(ch,c1,smoothstep(border-blur,border+blur,stripe_p));
    border=w[0]+0.5*(1.0-b)*w[1];
    ch=mix(ch,c2,smoothstep(border-blur,border+blur,stripe_p));
    border=w[0]+w[1];
    ch=mix(ch,c1,smoothstep(border-blur,border+blur,stripe_p));
    float gradient_t=(stripe_p-w[0]-w[1])/w[2];
    float gradient=mix(c1,c2,smoothstep(0.0,1.0,gradient_t));
    ch=mix(ch,gradient,smoothstep(border-blur,border+blur,stripe_p));
    return ch;
}

struct LiquidUniforms {
    float2 size;
    float  time;
    float  _pad0;
    float4 color1;      // light stripe
    float4 color2;      // dark stripe
    float4 bgColor;     // outside the rounded rect
    float  patternScale;
    float  waveSize;
    float  refraction;
    float  edge;
    float  patternBlur;
    float  liquid;
    float  grainIntensity;
    float  grainSpeed;
    float  grainMean;
    float  grainVariance;
    float  rectWidth;
    float  rectHeight;
    float  cornerRadius;
    float  edgeSoftness;
    float  speed;
    float  direction;
};

static inline half4 liquidGlass(float2 position, float2 size, float time,
    half4 color1, half4 color2, half4 bgColor,
    float patternScale, float waveSize, float refraction, float edge,
    float patternBlur, float liquid, float grainIntensity, float grainSpeed,
    float grainMean, float grainVariance, float rectWidth, float rectHeight,
    float cornerRadius, float edgeSoftness, float speed, float direction)
{
    float2 uv=position/max(size,float2(1.0));
    float ratio=size.x/max(size.y,1.0);
    float t=time*speed;
    float2 scaledUV=uv/max(waveSize,0.001);
    float2 centeredUV=scaledUV; centeredUV.x*=ratio;
    float2 distortedUV=centeredUV; distortedUV.y=1.0-distortedUV.y;
    { float ang=direction*TAU; float ca=cos(ang),sa=sin(ang);
      float2 dc=distortedUV-0.5;
      distortedUV=float2(ca*dc.x-sa*dc.y, sa*dc.x+ca*dc.y)+0.5; }
    float2 rectUV=uv-float2(0.5);
    float2 halfSize=float2(rectWidth,rectHeight)*0.5;
    float rectDist=liquid_rectDistance(rectUV,halfSize,cornerRadius,ratio);
    float rectMask=1.0-smoothstep(-edgeSoftness,0.0,rectDist);
    float diagonal=(distortedUV.x-distortedUV.y)*0.5;
    float3 col1=float3(color1.rgb), col2=float3(color2.rgb);
    col2.b+=0.1*smoothstep(0.7,1.3,distortedUV.x+distortedUV.y);
    float2 grad_uv=distortedUV-0.5;
    float dist=length(grad_uv+float2(0.0,0.2*diagonal));
    grad_uv=liquid_rotate(grad_uv,(0.25-0.2*diagonal)*PI);
    float bulge=pow(1.5*dist,1.0); bulge=1.0-bulge;
    bulge*=pow(max(0.1,distortedUV.y),0.2); bulge*=rectMask;
    float cycle_width=patternScale;
    float thin_strip_1_ratio=0.12/cycle_width*(1.0-0.4*bulge);
    float thin_strip_2_ratio=0.07/cycle_width*(1.0+0.4*bulge);
    float wide_strip_ratio=1.0-thin_strip_1_ratio-thin_strip_2_ratio;
    float thin_strip_1_width=max(0.001,cycle_width*thin_strip_1_ratio);
    float thin_strip_2_width=max(0.001,cycle_width*thin_strip_2_ratio);
    float noise=liquid_snoise((distortedUV-t)*0.9); noise*=rectMask;
    float edgeAmt=edge+(1.0-edge)*liquid*noise;
    float refr=clamp(1.0-bulge,0.0,1.0);
    float dir=grad_uv.x; dir+=diagonal*0.4;
    dir-=2.0*noise*diagonal*(smoothstep(0.0,1.0,edgeAmt)*smoothstep(1.0,0.0,edgeAmt));
    float bulge2=max(bulge,0.2*rectMask);
    dir*=(0.1+(1.1-edgeAmt)*bulge2);
    dir*=smoothstep(1.0,0.7,edgeAmt);
    dir+=0.18*(smoothstep(0.1,0.2,distortedUV.y)*smoothstep(0.4,0.2,distortedUV.y));
    dir+=0.03*(smoothstep(0.1,0.2,1.0-distortedUV.y)*smoothstep(0.4,0.2,1.0-distortedUV.y));
    dir*=(0.5+0.5*pow(distortedUV.y,2.0));
    dir*=cycle_width;
    dir-=t;
    dir=clamp(dir,-1000.0,1000.0);
    float refr_r=refr+0.03*bulge*noise;
    float refr_b=1.3*refr;
    refr_r+=5.0*(smoothstep(-0.1,0.2,distortedUV.y)*smoothstep(0.5,0.1,distortedUV.y))
               *(smoothstep(0.4,0.6,bulge2)*smoothstep(1.0,0.4,bulge2));
    refr_r-=diagonal*0.3;
    refr_b+=(smoothstep(0.0,0.4,distortedUV.y)*smoothstep(0.8,0.1,distortedUV.y))
           *(smoothstep(0.4,0.6,bulge2)*smoothstep(0.8,0.4,bulge2));
    refr_b-=0.2*edgeAmt;
    refr_r*=refraction*1.2;
    refr_b*=refraction*1.2;
    float3 w=float3(thin_strip_1_width,thin_strip_2_width,wide_strip_ratio);
    w[1]-=0.02*smoothstep(0.0,1.0,edgeAmt+bulge2);
    float stripe_r=liquid_mod_glsl(dir+refr_r,1.0);
    float r=liquid_get_channel(col1.r,col2.r,stripe_r,w,0.02+0.03*refraction*bulge2,bulge2,patternBlur);
    float stripe_g=liquid_mod_glsl(dir,1.0);
    float g=liquid_get_channel(col1.g,col2.g,stripe_g,w,max(0.001,0.01/(1.001-diagonal*0.3)),bulge2,patternBlur);
    float stripe_b=liquid_mod_glsl(dir-refr_b,1.0);
    float b=liquid_get_channel(col1.b,col2.b,stripe_b,w,0.01,bulge2,patternBlur);
    float3 col=float3(r,g,b);
    col=mix(float3(bgColor.rgb),col,rectMask);
    // Grain (additive)
    float seed=dot(uv,float2(12.9898,78.233));
    float gnoise=fract(sin(seed)*43758.5453+t*grainSpeed);
    gnoise=liquid_gauss(gnoise,grainMean,max(grainVariance*grainVariance,1e-4));
    col+=float3(gnoise)*(1.0-col)*grainIntensity;
    return half4(half3(saturate(col)),1.0);
}

fragment float4 liquid_fragment(VSOut in [[stage_in]],
                                constant LiquidUniforms& u [[buffer(0)]]) {
    half4 c = liquidGlass(in.pos.xy, u.size, u.time,
        half4(u.color1), half4(u.color2), half4(u.bgColor),
        u.patternScale, u.waveSize, u.refraction, u.edge, u.patternBlur, u.liquid,
        u.grainIntensity, u.grainSpeed, u.grainMean, u.grainVariance,
        u.rectWidth, u.rectHeight, u.cornerRadius, u.edgeSoftness, u.speed, u.direction);
    return float4(c);
}

// ===========================================================================
//  Combined effect: the neon Swirl seen THROUGH the Liquid Glass.
//  The glass contributes a height field (Fresnel bulge + animated Simplex
//  wobble); its gradient lenses the swirl, sampled per-channel for chromatic
//  refraction. A specular rim and film grain sit on top.
// ===========================================================================

// Glass surface height at a pixel — pure uniform ripples, full-bleed. No rounded
// rect mask and no central Fresnel bulge, so there's no circle or framed corners:
// the whole screen is one seamless sheet of liquid glass.
static inline float glass_height(float2 frag, constant LiquidUniforms& lu) {
    float2 size = lu.size;
    float2 uv = frag / max(size, float2(1.0));
    float ratio = size.x / max(size.y, 1.0);
    float t = lu.time * lu.speed;
    float2 p = uv / max(lu.waveSize, 0.001);
    p.x *= ratio;
    // Smooth, low-frequency surface waves. Low curvature so the lens bends the
    // swirl without focusing into caustic specks.
    float ripple = 0.78 * liquid_snoise((p * 2.2) - float2(t * 0.40, t * 0.18))
                 + 0.18 * liquid_snoise((p * 4.4) + float2(t * 0.28, -t * 0.38));
    return lu.liquid * ripple * 1.05;
}

static inline float3 combined_color(float2 frag,
                                    constant SwirlUniforms& su,
                                    constant LiquidUniforms& lu) {
    float2 size = lu.size;

    // Height + gradient (finite differences in pixels) -> lens normal.
    float e = 1.5;
    float h  = glass_height(frag, lu);
    float hx = glass_height(frag + float2(e, 0.0), lu);
    float hy = glass_height(frag + float2(0.0, e), lu);
    float2 grad = float2(hx - h, hy - h) / e;

    // Displacement that bends the swirl.
    float amp = lu.refraction * size.y * 110.0;
    float2 disp = grad * amp;

    // Chromatic dispersion: sample R/G/B along the refraction direction, offset
    // proportionally to the glass slope (grad) — flat glass → no offset → no
    // jitter. Then CLAMP the offset to a few pixels so a channel can never
    // sample far enough to fall to black (that was the dark-mark artifact):
    // dispersion stays a thin colored fringe. su.saturation = 0 keeps the body
    // monochrome.
    // Chromatic split along a FIXED axis (like lens chromatic aberration): a
    // constant few-pixel offset colors every swirl edge, is perfectly stable
    // (no direction jitter), and never focuses into marks. The glass displacement
    // still warps where each channel lands, so the color follows the liquid.
    // Only TWO swirl samples: G is the average of the R/B taps (the swirl is the
    // expensive part, so this ~1.5x's the whole shader).
    float2 caxis = float2(0.923, 0.385);      // fixed unit-ish direction
    float2 coff = caxis * (size.y * su.chroma);
    float3 col;
    col.r = swirl_color(frag + disp + coff, su).r;
    col.b = swirl_color(frag + disp - coff, su).b;
    col.g = 0.5 * (col.r + col.b);

    // Film grain (from the Liquid Glass source).
    float2 uv = frag / max(size, float2(1.0));
    float t = lu.time * lu.speed;
    float seed = dot(uv, float2(12.9898, 78.233));
    float gnoise = fract(sin(seed) * 43758.5453 + t * lu.grainSpeed);
    gnoise = liquid_gauss(gnoise, lu.grainMean, max(lu.grainVariance * lu.grainVariance, 1e-4));
    col += float3(gnoise) * (1.0 - col) * lu.grainIntensity;

    return clamp(col, 0.0, 1.0);
}

fragment float4 combined_fragment(VSOut in [[stage_in]],
                                  constant SwirlUniforms& su [[buffer(0)]],
                                  constant LiquidUniforms& lu [[buffer(1)]]) {
    return float4(combined_color(in.pos.xy, su, lu), 1.0);
}
