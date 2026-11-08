import { COLORS } from "../theme";
import { FeatureScene, LineBreak, PaperStack, useLayout } from "../components";

export const S2_Problem: React.FC = () => {
  const { portrait } = useLayout();

  return (
    <FeatureScene
      kicker="The problem"
      headline={
        <>
          Text shouldn&apos;t be<LineBreak only="portrait" />{" "}
          <span style={{ color: COLORS.blueBright }}>stuck on paper.</span>
        </>
      }
      body={
        <>
          Copying by hand is slow.
          <br />
          Searching isn&apos;t an option.
        </>
      }
      pills={["Photos", "Scans", "PDFs"]}
    >
      <PaperStack scale={portrait ? 1 : 0.86} />
    </FeatureScene>
  );
};
