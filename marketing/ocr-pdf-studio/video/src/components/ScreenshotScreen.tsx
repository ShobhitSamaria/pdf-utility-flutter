import {
  AbsoluteFill,
  Easing,
  Img,
  interpolate,
  staticFile,
  useCurrentFrame,
} from "remotion";
import { COLORS } from "../theme";

export const ScreenshotScreen: React.FC<{
  src: string;
  durationInFrames: number;
  startScale?: number;
  endScale?: number;
  focusX?: number;
  focusY?: number;
  scan?: boolean;
  scanDelay?: number;
}> = ({
  src,
  durationInFrames,
  startScale = 1,
  endScale = 1.08,
  focusX = 50,
  focusY = 50,
  scan = false,
  scanDelay = 0,
}) => {
  const frame = useCurrentFrame();
  const progress = interpolate(frame, [0, durationInFrames], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
  const scale = startScale + (endScale - startScale) * progress;
  const sweep = interpolate(
    frame,
    [scanDelay + 12, Math.max(scanDelay + 40, durationInFrames - 24)],
    [6, 94],
    { extrapolateLeft: "clamp", extrapolateRight: "clamp" },
  );
  const sweepOpacity = scan
    ? interpolate(
        frame,
        [scanDelay, scanDelay + 10, durationInFrames - 22, durationInFrames - 10],
        [0, 1, 0.75, 0],
        { extrapolateLeft: "clamp", extrapolateRight: "clamp" },
      )
    : 0;

  return (
    <AbsoluteFill style={{ overflow: "hidden", background: "#FAFAFC" }}>
      <Img
        src={staticFile(src)}
        style={{
          width: "100%",
          height: "100%",
          objectFit: "cover",
          transform: `scale(${scale})`,
          transformOrigin: `${focusX}% ${focusY}%`,
        }}
      />
      {scan ? (
        <div
          style={{
            position: "absolute",
            left: "7%",
            right: "7%",
            top: `${sweep}%`,
            height: 2,
            opacity: sweepOpacity,
            background: `linear-gradient(90deg, transparent 0%, ${COLORS.blueBright} 18%, ${COLORS.white} 50%, ${COLORS.blueBright} 82%, transparent 100%)`,
            boxShadow: `0 0 22px ${COLORS.blue}, 0 0 60px ${COLORS.blue}80`,
          }}
        />
      ) : null}
    </AbsoluteFill>
  );
};

export const ScreenSwap: React.FC<{
  first: string;
  second: string;
  durationInFrames: number;
  switchAt: number;
  firstFocus?: [number, number];
  secondFocus?: [number, number];
}> = ({ first, second, durationInFrames, switchAt, firstFocus = [50, 50], secondFocus = [50, 50] }) => {
  const frame = useCurrentFrame();
  const progress = interpolate(
    frame,
    [switchAt, switchAt + 12],
    [0, 1],
    {
      extrapolateLeft: "clamp",
      extrapolateRight: "clamp",
      easing: Easing.out(Easing.cubic),
    },
  );

  return (
    <AbsoluteFill style={{ overflow: "hidden", background: "#FAFAFC" }}>
      <AbsoluteFill
        style={{
          transform: `translateX(${-progress * 16}%)`,
          opacity: 1 - progress * 0.18,
        }}
      >
        <ScreenshotScreen
          src={first}
          durationInFrames={durationInFrames}
          startScale={1}
          endScale={1.035}
          focusX={firstFocus[0]}
          focusY={firstFocus[1]}
        />
      </AbsoluteFill>
      <AbsoluteFill
        style={{
          transform: `translateX(${(1 - progress) * 100}%)`,
          boxShadow: "-24px 0 48px rgba(0, 7, 48, 0.22)",
        }}
      >
        <ScreenshotScreen
          src={second}
          durationInFrames={durationInFrames}
          startScale={1.035}
          endScale={1.075}
          focusX={secondFocus[0]}
          focusY={secondFocus[1]}
          scan
          scanDelay={12}
        />
      </AbsoluteFill>
    </AbsoluteFill>
  );
};
