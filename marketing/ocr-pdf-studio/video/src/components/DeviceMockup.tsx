import { spring, useCurrentFrame, useVideoConfig } from "remotion";
import { COLORS } from "../theme";

/**
 * A slim Android device drawn around the real 1080 x 2160 captures.
 * The screen is exactly 1:2, matching the screenshots with no crop.
 */
export const DeviceMockup: React.FC<{
  children: React.ReactNode;
  screenWidth?: number;
  enterDelay?: number;
  tilt?: number;
  glow?: string;
}> = ({ children, screenWidth = 548, enterDelay = 0, tilt = 0, glow = COLORS.blue }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const enter = spring({
    frame,
    fps,
    delay: enterDelay,
    config: { mass: 0.95, damping: 18, stiffness: 82 },
  });

  const bezel = Math.max(10, Math.round(screenWidth * 0.021));
  const screenHeight = screenWidth * 2;
  const outerWidth = screenWidth + bezel * 2;
  const outerHeight = screenHeight + bezel * 2;
  const outerRadius = Math.round(screenWidth * 0.108);
  const screenRadius = outerRadius - bezel;
  const buttonWidth = Math.max(3, Math.round(screenWidth * 0.008));

  return (
    <div
      style={{
        position: "relative",
        width: outerWidth,
        height: outerHeight,
        opacity: enter,
        transform: `perspective(1600px) rotateY(${tilt}deg) translateY(${(1 - enter) * 34}px) scale(${0.94 + enter * 0.06})`,
        transformStyle: "preserve-3d",
      }}
    >
      {/* Coloured bloom behind the hardware. */}
      <div
        style={{
          position: "absolute",
          left: "50%",
          top: "50%",
          width: outerWidth * 1.16,
          height: outerHeight * 0.76,
          transform: "translate(-50%, -50%)",
          borderRadius: "50%",
          background: `radial-gradient(ellipse, ${glow}38 0%, ${glow}10 42%, transparent 72%)`,
          filter: "blur(48px)",
          zIndex: -1,
        }}
      />

      {/* Side buttons. */}
      <div
        style={{
          position: "absolute",
          right: -buttonWidth,
          top: outerHeight * 0.2,
          width: buttonWidth,
          height: outerHeight * 0.085,
          borderRadius: buttonWidth,
          background: "linear-gradient(180deg, #3A4264, #0A0E20)",
        }}
      />
      <div
        style={{
          position: "absolute",
          left: -buttonWidth,
          top: outerHeight * 0.17,
          width: buttonWidth,
          height: outerHeight * 0.052,
          borderRadius: buttonWidth,
          background: "linear-gradient(180deg, #3A4264, #0A0E20)",
        }}
      />
      <div
        style={{
          position: "absolute",
          left: -buttonWidth,
          top: outerHeight * 0.24,
          width: buttonWidth,
          height: outerHeight * 0.082,
          borderRadius: buttonWidth,
          background: "linear-gradient(180deg, #3A4264, #0A0E20)",
        }}
      />

      {/* Metal frame. */}
      <div
        style={{
          position: "absolute",
          inset: 0,
          borderRadius: outerRadius,
          background:
            "linear-gradient(145deg, #59648C 0%, #1A2144 16%, #050815 52%, #222B52 82%, #65749F 100%)",
          boxShadow: [
            "0 70px 140px rgba(0,0,0,0.58)",
            "0 28px 54px rgba(0,0,0,0.42)",
            "0 0 0 1px rgba(255,255,255,0.14) inset",
            `0 0 90px ${glow}20`,
          ].join(", "),
          padding: bezel,
        }}
      >
        <div
          style={{
            position: "relative",
            width: screenWidth,
            height: screenHeight,
            borderRadius: screenRadius,
            overflow: "hidden",
            background: "#FAFAFC",
            boxShadow: "0 0 0 1px rgba(0,0,0,0.8) inset",
          }}
        >
          {children}

          {/* Camera cut-out, placed over the empty centre of the status bar. */}
          <div
            style={{
              position: "absolute",
              top: Math.max(6, screenWidth * 0.014),
              left: "50%",
              transform: "translateX(-50%)",
              width: Math.max(7, screenWidth * 0.017),
              height: Math.max(7, screenWidth * 0.017),
              borderRadius: "50%",
              background: "#03050D",
              boxShadow: "0 0 0 2px rgba(255,255,255,0.05), 0 1px 4px rgba(0,0,0,0.8)",
              zIndex: 40,
            }}
          />

          {/* Glass reflection. */}
          <div
            style={{
              position: "absolute",
              inset: 0,
              background:
                "linear-gradient(118deg, transparent 28%, rgba(255,255,255,0.11) 44%, rgba(255,255,255,0.035) 50%, transparent 64%)",
              pointerEvents: "none",
              zIndex: 30,
            }}
          />
        </div>
      </div>
    </div>
  );
};
