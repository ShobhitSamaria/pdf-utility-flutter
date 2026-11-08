import { AbsoluteFill, interpolate } from "remotion";
import type {
  TransitionPresentation,
  TransitionPresentationComponentProps,
} from "@remotion/transitions";

/**
 * Fade through the continuous brand field. The outgoing scene is fully gone
 * before the incoming scene appears, so headlines and app screens never
 * double-expose. The shared navy background keeps the cut seamless.
 */
const FadeThroughPresentation: React.FC<
  TransitionPresentationComponentProps<Record<string, never>>
> = ({ children, presentationDirection, presentationProgress }) => {
  const entering = presentationDirection === "entering";
  const opacity = entering
    ? interpolate(presentationProgress, [0.46, 1], [0, 1], {
        extrapolateLeft: "clamp",
        extrapolateRight: "clamp",
      })
    : interpolate(presentationProgress, [0, 0.54], [1, 0], {
        extrapolateLeft: "clamp",
        extrapolateRight: "clamp",
      });

  return <AbsoluteFill style={{ opacity }}>{children}</AbsoluteFill>;
};

export const fadeThrough = (): TransitionPresentation<Record<string, never>> => ({
  component: FadeThroughPresentation,
  props: {},
});
