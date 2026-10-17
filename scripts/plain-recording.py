#!/usr/bin/env python3
"""Flatten a Terminal Text Effects recording to one colour and a still tail (development tool).

A recording made for a colour show does not suit a paper page: the effect
sweeps gradients and highlights across the text.  This tool rewrites every
frame with all colour runs dropped and each row that carries visible text
wrapped in a single foreground colour, which leaves the motion intact and the
picture monochrome.  It also appends a short still tail so the resolved text is
readable before the reel loops; a reel that knows its frame count plays that
tail once.  It needs the `terminaltexteffects` package installed
(`pip install terminaltexteffects`).  The output keeps the input header and
frame rate, and the input file is never written.

Usage:
  python3 plain-recording.py animation.tterec [--output plain.tterec]
      [--color '#2B3036'] [--hold 2]
"""

import argparse
import re
import sys
from pathlib import Path

from terminaltexteffects.engine._recording import (
    RecordingHeader,
    RecordingReader,
    RecordingWriter,
)

SGR = re.compile(r"\x1b\[[0-9;]*m")
COLOR = re.compile(r"#[0-9A-Fa-f]{6}\Z")
RESET = "\x1b[0m"


def plain(frame: str, sgr: str) -> str:
    """Return FRAME with every SGR run dropped and each visible row in one colour."""
    rows = []
    for row in frame.split("\n"):
        text = SGR.sub("", row)
        rows.append(f"{sgr}{text}{RESET}" if text.strip() else text)
    return "\n".join(rows)


def read_recording(path: Path) -> tuple[RecordingHeader, list[str], str]:
    """Return the header, frames and effect name of recording PATH.

    Only the package's public reader is used: a recording without segments is
    malformed, so it is reported instead of being repaired here.
    """
    with RecordingReader(path, keep_segment_names=True) as reader:
        frames = list(reader.frames())
        effect = reader.segments[0] if reader.segments else path.stem
        return reader.header, frames, effect


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("recording", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--color", default="#2B3036",
                        help="foreground colour for every row (default #2B3036)")
    parser.add_argument("--hold", type=float, default=2.0,
                        help="seconds of still tail to append (default 2)")
    arguments = parser.parse_args()

    if not COLOR.match(arguments.color):
        print(f"{arguments.color}: not a #RRGGBB colour", file=sys.stderr)
        return 1
    color = arguments.color.upper()
    output = arguments.output or arguments.recording.with_name(
        arguments.recording.stem + "-plain.tterec")
    if output.resolve() == arguments.recording.resolve():
        print(f"{output}: refusing to overwrite the input recording", file=sys.stderr)
        return 1
    if output.exists():
        print(f"{output}: already exists", file=sys.stderr)
        return 1

    header, frames, effect = read_recording(arguments.recording)
    if not frames:
        print(f"{arguments.recording}: no frames", file=sys.stderr)
        return 1
    hold = max(0, round(arguments.hold * header.frame_rate))
    sgr = "\x1b[38;2;{};{};{}m".format(*(int(color[index:index + 2], 16)
                                       for index in (1, 3, 5)))
    painted = [plain(frame, sgr) for frame in frames]
    with RecordingWriter(output, header) as writer:
        writer.begin_segment(effect)
        for frame in painted:
            writer.write_frame(frame)
        for _ in range(hold):
            writer.write_frame(painted[-1])
    print(f"input={arguments.recording} output={output} "
          f"frames={writer.frame_count} added_hold={hold} color={color}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
