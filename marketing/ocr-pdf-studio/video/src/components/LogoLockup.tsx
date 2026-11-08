import { Img, interpolate, spring, staticFile, useCurrentFrame, useVideoConfig } from "remotion";
import { COLORS, FONT } from "../theme";

const TaglineWord: React.FC<{ word: string; index: number }> = ({ word, index }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const enter = spring({
    frame,
    fps,
    delay: 12 + index * 3,
    config: { mass: 0.55, damping: 15, stiffness: 125 },
  });

  return (
    <span
      style={{
        display: "inline-block",
        opacity: enter,
        transform: `translateY(${(1 - enter) * 12}px)`,
        marginRight: "0.28em",
      }}
    >
      {word}
    </span>
  );
};

export const LogoLockup: React.FC<{ closing?: boolean }> = ({ closing = false }) => {
  const frame = useCurrentFrame();
  const { fps, width, height } = useVideoConfig();
  const portrait = height > width;
  const logoSize = portrait ? 262 : 278;
  const enter = spring({
    frame,
    fps,
    delay: 0,
    config: { mass: 0.9, damping: 17, stiffness: 90 },
  });
  const opacity = interpolate(frame, [0, 10], [0.72, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
  const scanY = interpolate(frame, [0, 56], [-12, 112], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
  const scanOpacity = interpolate(frame, [0, 8, 42, 58], [0, 0.9, 0.65, 0], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
  const halo = interpolate(Math.sin(frame / 26), [-1, 1], [0.72, 1]);

  return (
    <div
      style={{
        position: "absolute",
        inset: 0,
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        justifyContent: "center",
        textAlign: "center",
        padding: portrait ? "0 70px" : "0 110px",
      }}
    >
      <div style={{ position: "relative", marginBottom: portrait ? 42 : 34 }}>
        <div
          style={{
            position: "absolute",
            inset: -60,
            borderRadius: "50%",
            background: `radial-gradient(circle, ${COLORS.blue}42 0%, ${COLORS.blue}10 38%, transparent 70%)`,
            filter: "blur(28px)",
            opacity: halo,
          }}
        />
        <div style={{ position: "relative", overflow: "hidden", borderRadius: logoSize * 0.26 }}>
          <Img
            src={staticFile("logo.png")}
            width={logoSize}
            height={logoSize}
            style={{
              display: "block",
              opacity,
              transform: `scale(${0.9 + enter * 0.1})`,
              boxShadow: `0 0 0 1px rgba(255,255,255,0.15) inset, 0 34px 80px rgba(0,0,0,0.5)`,
              borderRadius: logoSize * 0.26,
            }}
          />
          <div
            style={{
              position: "absolute",
              left: "4%",
              right: "4%",
              top: `${scanY}%`,
              height: 3,
              opacity: scanOpacity,
              background: `linear-gradient(90deg, transparent, ${COLORS.blueBright}, #FFFFFF, ${COLORS.blueBright}, transparent)`,
              boxShadow: `0 0 18px ${COLORS.blue}, 0 0 44px ${COLORS.blue}`,
            }}
          />
        </div>
      </div>

      <div
        style={{
          fontFamily: FONT,
          fontSize: portrait ? 90 : 96,
          lineHeight: 1,
          fontWeight: 800,
          letterSpacing: "-0.055em",
          color: COLORS.offWhite,
          opacity: interpolate(frame, [4, 18], [0.65, 1], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
          }),
          transform: `translateY(${(1 - enter) * 18}px)`,
        }}
      >
        OCR PDF Studio
      </div>

      <div
        style={{
          marginTop: portrait ? 24 : 20,
          fontFamily: FONT,
          fontSize: portrait ? 35 : 36,
          lineHeight: 1.2,
          fontWeight: 600,
          letterSpacing: "0.015em",
          color: "rgba(199,211,244,0.92)",
        }}
      >
        {"Scan. Extract. Convert.".split(" ").map((word, index) => (
          <TaglineWord key={word} word={word} index={index} />
        ))}
      </div>

      <div
        style={{
          marginTop: portrait ? 54 : 44,
          display: "flex",
          alignItems: "center",
          gap: 16,
          opacity: interpolate(frame, closing ? [36, 54] : [44, 62], [0, 1], {
            extrapolateLeft: "clamp",
            extrapolateRight: "clamp",
          }),
        }}
      >
        <span
          style={{
            width: 38,
            height: 1,
            background: "rgba(148,168,222,0.45)",
          }}
        />
        <span
          style={{
            fontFamily: FONT,
            fontSize: portrait ? 19 : 20,
            fontWeight: 650,
            letterSpacing: "0.19em",
            textTransform: "uppercase",
            color: "rgba(226,232,255,0.56)",
          }}
        >
          {closing ? "On-device · no account" : "On-device document tools"}
        </span>
        <span
          style={{
            width: 38,
            height: 1,
            background: "rgba(148,168,222,0.45)",
          }}
        />
      </div>
    </div>
  );
};
