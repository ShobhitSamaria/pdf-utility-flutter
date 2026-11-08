import type { AppConfig } from "./config";
import { COLORS } from "./theme";

export const appConfig: AppConfig = {
  app: {
    name: "OCR PDF Studio",
    tagline: "Scan. Extract. Convert.",
    icon: "logo.png",
    platform: "android",
  },
  brand: {
    primary: COLORS.appPrimary,
    primaryLight: COLORS.periwinklePale,
    background: COLORS.navy,
    surface: COLORS.navyRaised,
    textPrimary: COLORS.offWhite,
    textSecondary: COLORS.periwinkle,
    success: COLORS.blue,
    danger: "#FF5C7A",
    accent: COLORS.blue,
  },
  video: {
    fps: 30,
    width: 1080,
    height: 1920,
    device: "pixel-9",
    backgroundMusic: "music/cinematic-build.mp3",
    backgroundMusicVolume: 0.38,
  },
};
