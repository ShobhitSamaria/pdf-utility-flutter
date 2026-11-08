export const COLORS = {
  navy: "#000730",
  navySoft: "#070D2A",
  navyRaised: "#111A3D",
  appPrimary: "#242A5C",
  blue: "#0170FE",
  blueBright: "#4D9BFF",
  periwinkle: "#94A8DE",
  periwinklePale: "#EDEEFA",
  white: "#FFFFFF",
  offWhite: "#F7F8FF",
  body: "rgba(226, 232, 255, 0.72)",
  bodyStrong: "rgba(236, 240, 255, 0.88)",
  faint: "rgba(255, 255, 255, 0.12)",
  faintStrong: "rgba(255, 255, 255, 0.2)",
} as const;

export const FONT = "'Manrope', 'Helvetica Neue', Arial, sans-serif";

export const SCENE_COUNT = 8;

export const TRANSITION_FRAMES = 12;

export const SCENE_DURATIONS = [
  96, // opening
  112, // problem
  120, // scan
  110, // extract
  96, // translate
  124, // create PDF
  112, // searchable PDF
  124, // closing
] as const;

export const TOTAL_DURATION =
  SCENE_DURATIONS.reduce((sum, duration) => sum + duration, 0) -
  TRANSITION_FRAMES * (SCENE_DURATIONS.length - 1);
