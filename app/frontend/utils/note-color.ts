const palette = ['#f44336', '#2196f3', '#4caf50', '#ff9800', '#9c27b0'];

export function getVoiceColor(index: number): string {
  return palette[index % palette.length];
}
