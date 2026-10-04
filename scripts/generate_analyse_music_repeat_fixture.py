"""Generate an exact-grid repetitive MusicXML fixture for MusicAnalyse benchmarks."""

from __future__ import annotations

import argparse
from pathlib import Path


PITCHES = (
    ("C", 4),
    ("E", 4),
    ("G", 4),
    ("E", 4),
)


def note_xml(step: str, octave: int, duration: int) -> str:
    return (
        "<note>"
        f"<pitch><step>{step}</step><octave>{octave}</octave></pitch>"
        f"<duration>{duration}</duration>"
        "<voice>1</voice>"
        "</note>"
    )


def build_score(steps: int, grid_denominator: int) -> str:
    if steps <= 0:
        raise ValueError("steps must be positive")
    if grid_denominator <= 0:
        raise ValueError("grid_denominator must be positive")

    # MusicXML divisions are quarter-note divisions, so duration=1 creates
    # exact 1/grid_denominator-quarter events. Because every event boundary is
    # on that grid, rhythm_denominator(parsed) is exactly grid_denominator.
    measure_steps = 4 * grid_denominator
    measures = []
    consumed = 0
    measure_number = 1
    while consumed < steps:
        count = min(measure_steps, steps - consumed)
        notes = []
        for local_index in range(count):
            pitch = PITCHES[(consumed + local_index) % len(PITCHES)]
            notes.append(note_xml(pitch[0], pitch[1], 1))

        attributes = ""
        if measure_number == 1:
            attributes = (
                "<attributes>"
                f"<divisions>{grid_denominator}</divisions>"
                "<time><beats>4</beats><beat-type>4</beat-type></time>"
                "</attributes>"
            )
        measures.append(
            f'<measure number="{measure_number}">'
            f"{attributes}{''.join(notes)}"
            "</measure>"
        )
        consumed += count
        measure_number += 1

    return (
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<score-partwise version="4.0">'
        "<part-list>"
        '<score-part id="P1"><part-name>Repeated benchmark</part-name></score-part>'
        "</part-list>"
        f'<part id="P1">{"".join(measures)}</part>'
        "</score-partwise>"
    )


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate a repetitive MusicXML whose exact analysis grid has N steps."
    )
    parser.add_argument("output", type=Path)
    parser.add_argument("--steps", type=int, default=2352)
    parser.add_argument("--grid-denominator", type=int, default=16)
    args = parser.parse_args()

    xml = build_score(args.steps, args.grid_denominator)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(xml, encoding="utf-8")
    total_quarters = args.steps / args.grid_denominator
    print(
        "generated_analyse_music_fixture,"
        f"path={args.output},steps={args.steps},"
        f"grid_denominator={args.grid_denominator},"
        f"total_quarters={total_quarters:g}"
    )


if __name__ == "__main__":
    main()
