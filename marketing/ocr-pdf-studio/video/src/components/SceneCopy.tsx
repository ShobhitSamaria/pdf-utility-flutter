import { spring, useCurrentFrame, useVideoConfig } from "remotion";
import { COLORS, FONT } from "../theme";
import { useLayout } from "./layout";

export const Rise: React.FC<{
  children: React.ReactNode;
  delay?: number;
  distance?: number;
  style?: React.CSSProperties;
}> = ({ children, delay = 0, distance = 26, style }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const progress = spring({
    frame,
    fps,
    delay,
    config: { mass: 0.72, damping: 17, stiffness: 105 },
  });

  return (
    <div
      style={{
        opacity: progress,
        transform: `translateY(${(1 - progress) * distance}px)`,
        ...style,
      }}
    >
      {children}
    </div>
  );
};

export const LineBreak: React.FC<{ only?: "portrait" | "landscape" }> = ({
  only,
}) => {
  const { portrait } = useLayout();
  if (only === "portrait" && !portrait) return null;
  if (only === "landscape" && portrait) return null;
  return <br />;
};

export const SceneCopy: React.FC<{
  kicker: string;
  headline: React.ReactNode;
  body: React.ReactNode;
  pills: string[];
  align?: "left" | "center";
}> = ({ kicker, headline, body, pills, align = "left" }) => {
  const { titleSize, bodySize, kickerSize, pillSize, copyGap, copyWidth } = useLayout();
  const centered = align === "center";

  return (
    <div
      style={{
        width: "100%",
        maxWidth: copyWidth,
        textAlign: centered ? "center" : "left",
        display: "flex",
        flexDirection: "column",
        alignItems: centered ? "center" : "flex-start",
      }}
    >
      <Rise delay={0} distance={16}>
        <div
          style={{
            display: "flex",
            alignItems: "center",
            gap: 14,
            marginBottom: copyGap,
          }}
        >
          <div
            style={{
              width: 34,
              height: 2,
              background: COLORS.blue,
              boxShadow: `0 0 16px ${COLORS.blue}99`,
            }}
          />
          <span
            style={{
              fontFamily: FONT,
              fontSize: kickerSize,
              fontWeight: 700,
              letterSpacing: "0.18em",
              textTransform: "uppercase",
              color: COLORS.periwinkle,
            }}
          >
            {kicker}
          </span>
        </div>
      </Rise>

      <Rise delay={5} distance={30}>
        <div
          style={{
            fontFamily: FONT,
            fontSize: titleSize,
            lineHeight: 1.02,
            fontWeight: 750,
            letterSpacing: "-0.048em",
            color: COLORS.offWhite,
          }}
        >
          {headline}
        </div>
      </Rise>

      <Rise delay={13} distance={24}>
        <p
          style={{
            margin: `${copyGap}px 0 0`,
            maxWidth: centered ? 760 : 680,
            fontFamily: FONT,
            fontSize: bodySize,
            lineHeight: 1.42,
            fontWeight: 450,
            letterSpacing: "-0.015em",
            color: COLORS.body,
          }}
        >
          {body}
        </p>
      </Rise>

      <Rise delay={21} distance={20}>
        <div
          style={{
            display: "flex",
            flexWrap: "wrap",
            justifyContent: centered ? "center" : "flex-start",
            gap: 12,
            marginTop: copyGap + 4,
          }}
        >
          {pills.map((pill) => (
            <div
              key={pill}
              style={{
                display: "flex",
                alignItems: "center",
                gap: 10,
                padding: "11px 17px",
                borderRadius: 999,
                border: `1px solid ${COLORS.faintStrong}`,
                background: "rgba(255,255,255,0.045)",
                boxShadow: "inset 0 1px 0 rgba(255,255,255,0.06)",
              }}
            >
              <span
                style={{
                  width: 7,
                  height: 7,
                  borderRadius: "50%",
                  background: COLORS.blue,
                  boxShadow: `0 0 10px ${COLORS.blue}`,
                }}
              />
              <span
                style={{
                  fontFamily: FONT,
                  fontSize: pillSize,
                  fontWeight: 600,
                  letterSpacing: "-0.01em",
                  color: COLORS.bodyStrong,
                  whiteSpace: "nowrap",
                }}
              >
                {pill}
              </span>
            </div>
          ))}
        </div>
      </Rise>
    </div>
  );
};
