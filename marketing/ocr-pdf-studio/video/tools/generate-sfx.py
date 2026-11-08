#!/usr/bin/env python3
"""Regenerate the original sound effects used in the promo.

These are synthesized from scratch (no samples) so the project carries no
third-party SFX rights. Run from anywhere:

    python3 tools/generate-sfx.py
"""

from __future__ import annotations

import math
import random
import struct
import wave
from pathlib import Path

SR = 44_100
OUT = Path(__file__).resolve().parents[1] / "public" / "sfx"
OUT.mkdir(parents=True, exist_ok=True)
random.seed(7)


def write(name: str, samples: list[float]) -> None:
    path = OUT / name
    with wave.open(str(path), "w") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(SR)
        frames = b"".join(
            struct.pack("<h", max(-32767, min(32767, int(sample * 32767))))
            for sample in samples
        )
        handle.writeframes(frames)
    print(f"{path}  {len(samples) / SR:.3f}s")


# Soft cinematic whoosh: filtered noise with a moving low-pass.
duration = 1.25
count = int(SR * duration)
whoosh: list[float] = []
low_pass = 0.0
previous = 0.0
for index in range(count):
    t = index / SR
    cutoff = 0.02 + 0.22 * math.sin(math.pi * min(1, t / duration)) ** 1.4
    white = random.uniform(-1, 1)
    low_pass += cutoff * (white - low_pass)
    high_pass = low_pass - previous * 0.985
    previous = low_pass
    amplitude = math.sin(math.pi * min(1, t / duration)) ** 2.2
    whoosh.append(high_pass * 0.55 * amplitude)
write("whoosh.wav", whoosh)

# Small tactile UI tick.
duration = 0.09
count = int(SR * duration)
tick: list[float] = []
for index in range(count):
    t = index / SR
    frequency = 1700 - 500 * t / duration
    tick.append(math.sin(2 * math.pi * frequency * t) * math.exp(-t * 70) * 0.45)
write("tick.wav", tick)

# Low impact for the opening bookend.
duration = 1.0
count = int(SR * duration)
impact: list[float] = []
low_pass = 0.0
for index in range(count):
    t = index / SR
    frequency = 68 - 24 * min(1, t / duration)
    body = math.sin(2 * math.pi * frequency * t) * math.exp(-t * 3.1)
    white = random.uniform(-1, 1)
    low_pass += 0.015 * (white - low_pass)
    impact.append((body * 0.55 + low_pass * 0.35) * min(1, t / 0.008))
write("impact.wav", impact)
