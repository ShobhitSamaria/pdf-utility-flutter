import { COLORS } from "../theme";
import { DeviceMockup, FeatureScene, ScreenshotScreen, useLayout } from "../components";

export const S7_Searchable: React.FC = () => {
  const { phoneScreenWidth } = useLayout();

  return (
    <FeatureScene
      kicker="05 / Searchable PDF"
      headline={
        <>
          Make scanned PDFs <span style={{ color: COLORS.blueBright }}>searchable.</span>
        </>
      }
      body="Turn a flat PDF into a searchable one."
      pills={["Searchable", "Save", "Share"]}
    >
      <DeviceMockup screenWidth={phoneScreenWidth} enterDelay={2}>
        <ScreenshotScreen
          src="screenshots/06_searchable_pdf.png"
          durationInFrames={112}
          startScale={1}
          endScale={1.1}
          focusX={50}
          focusY={56}
          scan={false}
        />
      </DeviceMockup>
    </FeatureScene>
  );
};
