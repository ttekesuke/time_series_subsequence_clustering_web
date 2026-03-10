export type GridStructuredClipboardType = 'rows' | 'cols'

export type GridCellValue = number | string

export type GridStructuredClipboard = {
  type: GridStructuredClipboardType;
  matrix: GridCellValue[][];
  text: string;
}

let structuredClipboard: GridStructuredClipboard | null = null

export const getStructuredClipboard = (): GridStructuredClipboard | null => structuredClipboard

export const setStructuredClipboard = (value: GridStructuredClipboard | null): void => {
  structuredClipboard = value
}
