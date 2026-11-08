import { AbsoluteFill, interpolate, useCurrentFrame, useVideoConfig } from "remotion";
import { COLORS } from "../theme";

/**
 * One continuous brand field sits behind every scene, so transitions never
 * fade through black. The rings and light beam move slowly enough to read as
 * camera movement rather than decoration.
 */
export const BrandBackground: React.FC<{
  accent?: string;
  intensity?: number;
}> = ({ accent = COLORS.blue, intensity = 1 }) => {
  const frame = useCurrentFrame();
  const { width, height } = useVideoConfig();
  const portrait = height > width;

  const driftX = Math.sin(frame / 105) * 34;
  const driftY = Math.cos(frame / 128) * 24;
  const ringPulse = interpolate(Math.sin(frame / 48), [-1, 1], [0.94, 1.04]);
  const beamX = interpolate(frame, [0, 810], [-260, 260]);

  return (
    <AbsoluteFill style={{ background: COLORS.navy, overflow: "hidden" }}>
      {/* Deep navy volume, biased to the upper left. */}
      <div
        style={{
          position: "absolute",
          inset: -240,
          background: `radial-gradient(circle at ${28 + driftX / 20}% ${22 + driftY / 20}%, rgba(42, 52, 112, 0.92) 0%, rgba(10, 17, 49, 0.58) 38%, rgba(0, 7, 48, 0) 70%)`,
        }}
      />

      {/* Electric-blue bloom, kept away from the typography. */}
      <div
        style={{
          position: "absolute",
          width: portrait ? 880 : 1050,
          height: portrait ? 880 : 1050,
          right: portrait ? -420 : -220,
          bottom: portrait ? -260 : -420,
          borderRadius: "50%",
          background: `radial-gradient(circle, ${accent}55 0%, ${accent}18 38%, transparent 70%)`,
          filter: "blur(42px)",
          opacity: 0.9 * intensity,
        }}
      />

      {/* Soft periwinkle counter-light. */}
      <div
        style={{
          position: "absolute",
          width: portrait ? 620 : 760,
          height: portrait ? 620 : 760,
          left: portrait ? -300 : -180,
          bottom: portrait ? 300 : -260,
          borderRadius: "50%",
          background:
            "radial-gradient(circle, rgba(148,168,222,0.18) 0%, rgba(148,168,222,0.06) 45%, transparent 72%)",
          filter: "blur(50px)",
        }}
      />

      {/* Fine technical grid. */}
      <div
        style={{
          position: "absolute",
          inset: 0,
          backgroundImage:
            "linear-gradient(rgba(255,255,255,0.045) 1px, transparent 1px), linear-gradient(90deg, rgba(255,255,255,0.045) 1px, transparent 1px)",
          backgroundSize: portrait ? "72px 72px" : "84px 84px",
          opacity: 0.52,
          maskImage:
            "radial-gradient(ellipse at 50% 45%, rgba(0,0,0,0.95) 0%, rgba(0,0,0,0.4) 52%, transparent 78%)",
          WebkitMaskImage:
            "radial-gradient(ellipse at 50% 45%, rgba(0,0,0,0.95) 0%, rgba(0,0,0,0.4) 52%, transparent 78%)",
        }}
      />

      {/* Slow diagonal light sweep. */}
      <div
        style={{
          position: "absolute",
          top: -220,
          left: portrait ? -420 + beamX : -260 + beamX,
          width: portrait ? 260 : 360,
          height: portrait ? 2400 : 1500,
          transform: "rotate(19deg)",
          background:
            "linear-gradient(90deg, transparent 0%, rgba(120,168,255,0.08) 38%, rgba(255,255,255,0.12) 50%, rgba(120,168,255,0.05) 62%, transparent 100%)",
          filter: "blur(14px)",
        }}
      />

      {/* Concentric navigation rings. */}
      {[0, 1, 2].map((index) => {
        const size = (portrait ? 560 : 640) + index * (portrait ? 180 : 210);
        return (
          <div
            key={index}
            style={{
              position: "absolute",
              width: size,
              height: size,
              right: portrait ? -size * 0.44 : -size * 0.34,
              top: portrait ? -size * 0.28 : -size * 0.38,
              borderRadius: "50%",
              border: `1px solid rgba(148,168,222,${0.14 - index * 0.028})`,
              transform: `scale(${ringPulse + index * 0.004}) rotate(${frame * 0.015 + index * 8}deg)`,
            }}
          />
        );
      })}

      {/* Near-invisible registration ticks. */}
      <div
        style={{
          position: "absolute",
          left: portrait ? 56 : 72,
          top: portrait ? 54 : 48,
          width: 26,
          height: 26,
          borderLeft: "1px solid rgba(255,255,255,0.22)",
          borderTop: "1px solid rgba(255,255,255,0.22)",
        }}
      />
      <div
        style={{
          position: "absolute",
          right: portrait ? 56 : 72,
          bottom: portrait ? 54 : 48,
          width: 26,
          height: 26,
          borderRight: "1px solid rgba(255,255,255,0.22)",
          borderBottom: "1px solid rgba(255,255,255,0.22)",
        }}
      />

      {/* Vignette keeps the centre luminous and the edges quiet. */}
      <div
        style={{
          position: "absolute",
          inset: 0,
          background:
            "radial-gradient(ellipse at 50% 48%, transparent 32%, rgba(0,4,26,0.32) 72%, rgba(0,3,20,0.72) 100%)",
        }}
      />
    </AbsoluteFill>
  );
};
