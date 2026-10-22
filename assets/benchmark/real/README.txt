Real-photograph benchmark samples live here.

Each sample is a pair:

  <name>.jpg   the photograph
  <name>.txt   its exact transcription

plus one entry per sample in ../manifest.json. Both files and the entry are
required; a photograph without a transcription cannot be scored.

This directory ships with only this file so the asset bundle path exists. The
harness reports the real-photograph tier as NOT MEASURED until samples are
added, because synthetic samples are digital renderings and say nothing about
how the app behaves on a photo taken with a hand-held phone.

Full instructions, the category list and advice on capturing a useful set of
samples are in docs/OCR_BENCHMARK.md.
