import { Img, interpolate, staticFile, useCurrentFrame } from "remotion";
import { COLORS, FONT } from "../theme";

/**
 * A document still-life built from the real invoice page in the review-screen
 * capture. The backing sheets are deliberately abstract so nothing here reads
 * as a fabricated app screen.
 */
export const PaperStack: React.FC<{ scale?: number }> = ({ scale = 1 }) => {
  const frame = useCurrentFrame();
  const float = Math.sin(frame / 34) * 5;
  const drift = interpolate(frame, [0, 160], [-2, 2], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

  return (
    <div
      style={{
        position: "relative",
        width: 660 * scale,
        height: 790 * scale,
        transform: `translateY(${float}px)`,
      }}
    >
      <div
        style={{
          position: "absolute",
          left: 70 * scale,
          top: 52 * scale,
          width: 520 * scale,
          height: 670 * scale,
          borderRadius: 18 * scale,
          background: "#E9E6DD",
          transform: `rotate(${-8 + drift}deg)`,
          boxShadow: "0 38px 90px rgba(0,0,0,0.45)",
        }}
      />
      <div
        style={{
          position: "absolute",
          left: 92 * scale,
          top: 40 * scale,
          width: 520 * scale,
          height: 670 * scale,
          borderRadius: 18 * scale,
          background: "#F4F1E9",
          transform: `rotate(${4 - drift}deg)`,
          boxShadow: "0 38px 90px rgba(0,0,0,0.42)",
        }}
      />

      <div
        style={{
          position: "absolute",
          left: 70 * scale,
          top: 32 * scale,
          width: 520 * scale,
          height: 670 * scale,
          borderRadius: 18 * scale,
          overflow: "hidden",
          background: "#FAFAF7",
          transform: `rotate(${-1.5 + drift * 0.4}deg)`,
          boxShadow: "0 55px 120px rgba(0,0,0,0.55), 0 0 0 1px rgba(255,255,255,0.3) inset",
        }}
      >
        <Img
          src={staticFile("screenshots/invoice-page.png")}
          style={{
            width: "100%",
            height: "100%",
            objectFit: "contain",
            objectPosition: "50% 50%",
            transform: "scale(1)",
          }}
        />
        <div
          style={{
            position: "absolute",
            inset: 0,
            background:
              "linear-gradient(180deg, rgba(0,7,48,0.04) 0%, transparent 22%, transparent 72%, rgba(0,7,48,0.2) 100%)",
          }}
        />
      </div>

      <div
        style={{
          position: "absolute",
          right: 2 * scale,
          bottom: 58 * scale,
          padding: `${12 * scale}px ${18 * scale}px`,
          borderRadius: 999,
          border: "1px solid rgba(148,168,222,0.36)",
          background: "rgba(0,7,48,0.82)",
          boxShadow: "0 16px 40px rgba(0,0,0,0.35)",
          display: "flex",
          alignItems: "center",
          gap: 10 * scale,
          transform: `rotate(2deg)`,
        }}
      >
        <span
          style={{
            width: 8 * scale,
            height: 8 * scale,
            borderRadius: "50%",
            background: COLORS.periwinkle,
          }}
        />
        <span
          style={{
            fontFamily: FONT,
            fontSize: 22 * scale,
            fontWeight: 600,
            letterSpacing: "-0.01em",
            color: COLORS.bodyStrong,
            whiteSpace: "nowrap",
          }}
        >
          Flat image · no text layer
        </span>
      </div>
    </div>
  );
};
