/** Scan without expanding the whole series into function arguments. */
export function seriesBounds(values: readonly number[]): { min: number; max: number } {
  if (values.length === 0) return { min: 0, max: 127 }

  let min = Infinity
  let max = -Infinity
  for (const value of values) {
    min = Math.min(min, value)
    max = Math.max(max, value)
  }
  return { min, max }
}
