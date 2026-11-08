import { useVideoConfig } from "remotion";

export const useLayout = () => {
  const { width, height } = useVideoConfig();
  const portrait = height > width;

  return {
    portrait,
    canvasWidth: width,
    canvasHeight: height,
    padX: portrait ? 76 : 104,
    copyWidth: portrait ? 928 : 730,
    phoneScreenWidth: portrait ? 548 : 458,
    titleSize: portrait ? 72 : 76,
    bodySize: portrait ? 31 : 30,
    kickerSize: 20,
    pillSize: 22,
    copyGap: portrait ? 26 : 24,
  };
};
