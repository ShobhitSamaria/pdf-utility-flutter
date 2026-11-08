import { COLORS } from "../theme";
import { DeviceMockup, FeatureScene, LineBreak, ScreenshotScreen, useLayout } from "../components";

export const S5_Translate: React.FC = () => {
  const { phoneScreenWidth } = useLayout();

  return (
    <FeatureScene
      kicker="03 / Translate"
      headline={
        <>
          Translation,<LineBreak only="landscape" />{" "}
          <span style={{ color: COLORS.blueBright }}>on your device.</span>
        </>
      }
      body="Pick a language. Your page stays on your device."
      pills={["English ↔ हिन्दी", "On-device"]}
    >
      <DeviceMockup screenWidth={phoneScreenWidth} enterDelay={2} glow={COLORS.periwinkle}>
        <ScreenshotScreen
          src="screenshots/04_translation.png"
          durationInFrames={96}
          startScale={1}
          endScale={1.07}
          focusX={50}
          focusY={58}
          scan={false}
        />
      </DeviceMockup>
    </FeatureScene>
  );
};
