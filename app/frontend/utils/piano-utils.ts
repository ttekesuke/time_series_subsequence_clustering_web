import type { Voice, TimeSignature } from '../types/types';

export function drawPianoRoll(
  ctx: CanvasRenderingContext2D,
  voices: Voice[],
  timeSignature: TimeSignature,
  beatWidth: number,
  width: number,
  height: number
) {
  ctx.clearRect(0, 0, width, height);
  drawGrid(ctx, timeSignature, beatWidth, width, height);
  drawNotes(ctx, voices, beatWidth);
}

function drawGrid(
  ctx: CanvasRenderingContext2D,
  timeSignature: TimeSignature,
  beatWidth: number,
  width: number,
  height: number
) {
  const beatsPerMeasure = timeSignature.numerator;
  for (let i = 0; i < width / beatWidth; i++) {
    const x = i * beatWidth;
    ctx.strokeStyle = i % beatsPerMeasure === 0 ? '#888' : '#ccc';
    ctx.beginPath();
    ctx.moveTo(x, 0);
    ctx.lineTo(x, height);
    ctx.stroke();
  }
}

function drawNotes(
  ctx: CanvasRenderingContext2D,
  voices: Voice[],
  beatWidth: number
) {
  const visibleMinPitch = 0;
  const visibleMaxPitch = 84;
  const noteRange = visibleMaxPitch - visibleMinPitch;
  const noteHeight = 300 / noteRange; // 高さに収まるようにスケーリング

  voices.forEach((voice) => {
    let time = 0;
    voice.timeline.forEach((group) => {
      const durationPx = group.duration * beatWidth * 4;
      if ('pitches' in group) {
        group.pitches.forEach((pitch) => {
          if (pitch < visibleMinPitch || pitch > visibleMaxPitch) return;
          const y = (visibleMaxPitch - pitch) * noteHeight;
          ctx.fillStyle = voice.color;
          ctx.fillRect(time, y, durationPx, noteHeight - 1);
        });
      }
      time += durationPx;
    });
  });
}

