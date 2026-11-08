import { AbsoluteFill } from "remotion";
import { SceneCopy } from "./SceneCopy";
import { useLayout } from "./layout";

export const FeatureScene: React.FC<{
  kicker: string;
  headline: React.ReactNode;
  body: React.ReactNode;
  pills: string[];
  children: React.ReactNode;
}> = ({ kicker, headline, body, pills, children }) => {
  const { portrait, padX } = useLayout();

  return (
    <AbsoluteFill>
      {portrait ? (
        <div
          style={{
            position: "absolute",
            inset: 0,
            display: "flex",
            flexDirection: "column",
            alignItems: "center",
            padding: `64px ${padX}px 40px`,
          }}
        >
          <SceneCopy kicker={kicker} headline={headline} body={body} pills={pills} />
          <div
            style={{
              flex: 1,
              width: "100%",
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              paddingTop: 12,
            }}
          >
            {children}
          </div>
        </div>
      ) : (
        <div
          style={{
            position: "absolute",
            inset: 0,
            display: "flex",
            alignItems: "center",
            padding: `0 ${padX}px`,
            gap: 70,
          }}
        >
          <div style={{ width: 730, flexShrink: 0 }}>
            <SceneCopy kicker={kicker} headline={headline} body={body} pills={pills} />
          </div>
          <div
            style={{
              flex: 1,
              height: "100%",
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
            }}
          >
            {children}
          </div>
        </div>
      )}
    </AbsoluteFill>
  );
};
