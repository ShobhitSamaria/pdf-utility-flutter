import { AbsoluteFill, Audio, interpolate, Sequence, staticFile } from "remotion";
import { linearTiming, TransitionSeries } from "@remotion/transitions";
import { BrandBackground, fadeThrough } from "./components";
import {
  SCENE_DURATIONS,
  TOTAL_DURATION,
  TRANSITION_FRAMES,
} from "./theme";
import { S1_Open } from "./scenes/S1_Open";
import { S2_Problem } from "./scenes/S2_Problem";
import { S3_Scan } from "./scenes/S3_Scan";
import { S4_Extract } from "./scenes/S4_Extract";
import { S5_Translate } from "./scenes/S5_Translate";
import { S6_CreatePdf } from "./scenes/S6_CreatePdf";
import { S7_Searchable } from "./scenes/S7_Searchable";
import { S8_Close } from "./scenes/S8_Close";

const SCENES = [
  S1_Open,
  S2_Problem,
  S3_Scan,
  S4_Extract,
  S5_Translate,
  S6_CreatePdf,
  S7_Searchable,
  S8_Close,
];

/** First frame of every scene once the 12-frame transitions are accounted for. */
const SCENE_STARTS = SCENE_DURATIONS.map((_, index) =>
  SCENE_DURATIONS.slice(0, index).reduce((sum, duration) => sum + duration, 0) -
  TRANSITION_FRAMES * index,
);

const TRANSITION_BOUNDARIES = SCENE_STARTS.slice(1);

/** Whooshes lead the cut by about half a second, the way a real edit does. */
const WHOOSH_LEAD = 14;

/** Tactile ticks land on screen changes, not on every line of copy. */
const TICK_FRAMES = [
  SCENE_STARTS[2] + 58, // home -> live scan screen
  SCENE_STARTS[3] + 14, // extracted text scan line
  SCENE_STARTS[5] + 20, // create-PDF review scan line
  SCENE_STARTS[6] + 40, // searchable-PDF result
];

export const OcrPdfStudioPreview: React.FC = () => {
  return (
    <AbsoluteFill style={{ background: "#000730" }}>
      {/* One unbroken brand field: transitions never dip to black. */}
      <BrandBackground />

      <TransitionSeries>
        {SCENES.map((Scene, index) => (
          <TransitionSeries.Sequence
            key={index}
            durationInFrames={SCENE_DURATIONS[index]}
          >
            <Scene />
          </TransitionSeries.Sequence>
        )).flatMap((sequence, index) =>
          index === SCENES.length - 1
            ? [sequence]
            : [
                sequence,
                <TransitionSeries.Transition
                  key={`transition-${index}`}
                  presentation={fadeThrough()}
                  timing={linearTiming({ durationInFrames: TRANSITION_FRAMES })}
                />,
              ],
        )}
      </TransitionSeries>

      {/* Licensed score, faded at both ends. The track has a quiet lead-in,
          so start two seconds in and use the build across the full cut. */}
      <Audio
        src={staticFile("music/cinematic-build.mp3")}
        startFrom={60}
        volume={(frame) =>
          interpolate(
            frame,
            [0, 26, TOTAL_DURATION - 42, TOTAL_DURATION],
            [0, 0.75, 0.7, 0],
            { extrapolateLeft: "clamp", extrapolateRight: "clamp" },
          )
        }
      />

      {/* Opening impact. */}
      <Sequence from={2} durationInFrames={30} layout="none">
        <Audio src={staticFile("sfx/impact.wav")} volume={0.4} />
      </Sequence>

      {/* Air for every scene change. */}
      {TRANSITION_BOUNDARIES.map((boundary, index) => (
        <Sequence
          key={`whoosh-${index}`}
          from={Math.max(0, boundary - WHOOSH_LEAD)}
          durationInFrames={42}
          layout="none"
        >
          <Audio src={staticFile("sfx/whoosh.wav")} volume={0.3} />
        </Sequence>
      ))}

      {/* Small interface ticks. */}
      {TICK_FRAMES.map((tick, index) => (
        <Sequence key={`tick-${index}`} from={tick} durationInFrames={6} layout="none">
          <Audio src={staticFile("sfx/tick.wav")} volume={0.2} />
        </Sequence>
      ))}
    </AbsoluteFill>
  );
};
