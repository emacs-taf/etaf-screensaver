#!/usr/bin/env python3
"""Trim the still tail from a Terminal Text Effects recording (development tool).

A TTE recording usually ends with the resolved text sitting still.  For a
screensaver reel that still tail is dead time, so this tool keeps the frames
through the last visible change (plus a short hold) and drops the rest, which
makes the loop replay the motion instead of freezing.  It needs the
`terminaltexteffects` package installed (`pip install terminaltexteffects`).
The output keeps the same header and frame rate; import it like any other
recording.

Usage:
  python3 trim-recording.py animation.tterec [--output trimmed.tterec]
      [--hold 0.4] [--min-frames 24]
"""

import argparse
import re
import sys
from pathlib import Path

from terminaltexteffects.engine._recording import RecordingReader, RecordingWriter

SGR = re.compile(r"\x1b\[[0-9;]*m")


def visible(frame: str) -> str:
    """Return FRAME with its SGR runs removed; only for external callers."""
    return SGR.sub("", frame)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("recording", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--hold", type=float, default=0.4,
                        help="seconds of the last frame to keep (default 0.4)")
    parser.add_argument("--min-frames", type=int, default=24,
                        help="never keep fewer frames than this (default 24)")
    arguments = parser.parse_args()

    with RecordingReader(arguments.recording, keep_segment_names=True) as reader:
        header = reader.header
        frames = list(reader.frames())
        segments = list(reader.segments)
    if not frames:
        print(f"{arguments.recording}: no frames", file=sys.stderr)
        return 1

    # Compare whole frames: colour-only animation (for example a spotlight
    # sweeping over settled text) is motion too.
    last_change = 0
    previous = frames[0]
    for index, frame in enumerate(frames[1:], start=1):
        if frame != previous:
            last_change = index
            previous = frame

    hold = max(0, round(arguments.hold * header.frame_rate))
    keep = min(len(frames), max(arguments.min_frames, last_change + 1 + hold))
    output = arguments.output or arguments.recording.with_name(
        arguments.recording.stem + ".trimmed.tterec")
    with RecordingWriter(output, header) as writer:
        writer.begin_segment(segments[0] if segments else arguments.recording.stem)
        for frame in frames[:keep]:
            writer.write_frame(frame)
    print(f"{arguments.recording.name}: frames={len(frames)} last_change={last_change} "
          f"keep={keep} seconds={keep / header.frame_rate:.1f} -> {output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
