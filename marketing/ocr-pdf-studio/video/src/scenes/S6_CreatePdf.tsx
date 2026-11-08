import { COLORS } from "../theme";
import { DeviceMockup, FeatureScene, LineBreak, ScreenshotScreen, useLayout } from "../components";

export const S6_CreatePdf: React.FC = () => {
  const { phoneScreenWidth } = useLayout();

  return (
    <FeatureScene
      kicker="04 / Create PDF"
      headline={
        <>
          Your pages.<LineBreak only="landscape" />{" "}
          <span style={{ color: COLORS.blueBright }}>A real PDF.</span>
        </>
      }
      body="Review, reorder, name and compress."
      pills={["2 pages", "Standard / Compress", "One tap"]}
    >
      <DeviceMockup screenWidth={phoneScreenWidth} enterDelay={2}>
        <ScreenshotScreen
          src="screenshots/05_create_pdf.png"
          durationInFrames={124}
          startScale={1}
          endScale={1.1}
          focusX={50}
          focusY={40}
          scan
          scanDelay={18}
        />
      </DeviceMockup>
    </FeatureScene>
  );
};
