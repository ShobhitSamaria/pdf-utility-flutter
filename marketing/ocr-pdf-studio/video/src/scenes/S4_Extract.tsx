import { COLORS } from "../theme";
import { DeviceMockup, FeatureScene, LineBreak, ScreenshotScreen, useLayout } from "../components";

export const S4_Extract: React.FC = () => {
  const { phoneScreenWidth } = useLayout();

  return (
    <FeatureScene
      kicker="02 / Extract"
      headline={
        <>
          Text you can{" "}
          <span style={{ color: COLORS.blueBright }}>
            copy<LineBreak />and search.
          </span>
        </>
      }
      body="The words on the page become selectable text, recognised on device."
      pills={["69 words found", "Find in text", "Copy all"]}
    >
      <DeviceMockup screenWidth={phoneScreenWidth} enterDelay={2}>
        <ScreenshotScreen
          src="screenshots/03_extracted_text.png"
          durationInFrames={110}
          startScale={1}
          endScale={1.14}
          focusX={50}
          focusY={42}
          scan
          scanDelay={12}
        />
      </DeviceMockup>
    </FeatureScene>
  );
};
