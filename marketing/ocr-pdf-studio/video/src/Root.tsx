import { loadFont } from "@remotion/fonts";
import { Composition, staticFile } from "remotion";
import { appConfig } from "./app-config";
import { OcrPdfStudioPreview } from "./OcrPdfStudioPreview";
import { TOTAL_DURATION } from "./theme";
import "./styles.css";

// Bundled Manrope variable font (SIL Open Font License).
loadFont({
  family: "Manrope",
  url: staticFile("fonts/Manrope-Variable.ttf"),
  weight: "200 800",
  style: "normal",
  display: "block",
});

export const RemotionRoot: React.FC = () => {
  return (
    <>
      <Composition
        id="OcrPdfStudio-Vertical"
        component={OcrPdfStudioPreview}
        durationInFrames={TOTAL_DURATION}
        fps={appConfig.video.fps}
        width={appConfig.video.width}
        height={appConfig.video.height}
      />
      <Composition
        id="OcrPdfStudio-Landscape"
        component={OcrPdfStudioPreview}
        durationInFrames={TOTAL_DURATION}
        fps={appConfig.video.fps}
        width={1920}
        height={1080}
      />
    </>
  );
};
