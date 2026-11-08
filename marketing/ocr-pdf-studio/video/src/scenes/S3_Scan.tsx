import { COLORS } from "../theme";
import { DeviceMockup, FeatureScene, LineBreak, ScreenSwap, useLayout } from "../components";

export const S3_Scan: React.FC = () => {
  const { phoneScreenWidth } = useLayout();

  return (
    <FeatureScene
      kicker="01 / Scan"
      headline={
        <>
          Start with a page.<LineBreak only="landscape" />{" "}
          <span style={{ color: COLORS.blueBright }}>Any page.</span>
        </>
      }
      body="Use the camera, your gallery, or an existing PDF."
      pills={["Camera", "Gallery", "PDF"]}
    >
      <DeviceMockup screenWidth={phoneScreenWidth} enterDelay={2}>
        <ScreenSwap
          first="screenshots/01_home.png"
          second="screenshots/02_ocr_scan.png"
          durationInFrames={120}
          switchAt={58}
          firstFocus={[50, 52]}
          secondFocus={[50, 46]}
        />
      </DeviceMockup>
    </FeatureScene>
  );
};
