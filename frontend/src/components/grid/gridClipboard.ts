export type GridStructuredClipboardType = 'rows' | 'cols'

export type GridStructuredClipboard = {
  type: GridStructuredClipboardType;
  matrix: number[][];
  text: string;
}

let structuredClipboard: GridStructuredClipboard | null = null

export const getStructuredClipboard = (): GridStructuredClipboard | null => structuredClipboard

export const setStructuredClipboard = (value: GridStructuredClipboard | null): void => {
  structuredClipboard = value
}
