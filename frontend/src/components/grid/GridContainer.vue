<template>
  <!-- フォーカス監視ラッパ -->
  <div
    class="grid-wrapper"
    ref="wrapperRef"
    tabindex="0"
    @focusout="onFocusOut"
    @copy="onWrapperCopy"
    @paste="onWrapperPaste"
  >
    <!-- ツールバー -->
    <v-toolbar density="compact" color="grey-lighten-4" class="px-2 mb-2 rounded sticky-toolbar">
      <v-toolbar-title class="text-subtitle-1 font-weight-bold">
        {{ title }}
      </v-toolbar-title>
      <v-spacer></v-spacer>

      <!-- Streams 管理（初期コンテキスト用） -->
      <div
        v-if="showStreamCount"
        class="d-flex align-center mr-4"
        style="font-size: 0.9rem;"
      >
        <span class="mr-2">Streams:</span>
        <input
          type="number"
          :value="streamCountDraft"
          @input="onStreamInput"
          @blur="onStreamBlur"
          min="1"
          max="16"
          class="step-input mr-1"
        >
      </div>

      <!-- 行数管理（汎用用） -->
      <div
        v-if="showRowsLength"
        class="d-flex align-center mr-4"
        style="font-size: 0.9rem;"
      >
        <span class="mr-2">Rows:</span>
        <input
          type="number"
          :value="rows.length"
          @input="updateRowCount($event)"
          min="1"
          max="32"
          class="step-input mr-1"
        >
      </div>

      <!-- 列数管理 -->
      <div
        v-if="showColsLength"
        class="d-flex align-center mr-4"
        style="font-size: 0.9rem;"
      >
        <span class="mr-2">Steps:</span>
        <input
          type="number"
          :value="stepsDraft"
          @input="onStepsInput"
          @blur="onStepsBlur"
          min="1"
          max="400"
          class="step-input mr-1"
        >
      </div>

      <slot name="toolbar-extra"></slot>

      <v-tooltip
        v-model="copiedTooltipVisible"
        :open-on-hover="false"
        :open-on-click="false"
        location="bottom"
      >
        <template #activator="{ props: tooltipProps }">
          <span class="copy-tooltip-anchor mr-2" v-bind="tooltipProps"></span>
        </template>
        copied!
      </v-tooltip>

      <!-- パラメータ生成ボタン -->
      <v-btn
        v-if="showGenerateParametersButton"
        color="secondary"
        size="small"
        :disabled="!canGenerateParameters"
        @click="openParamGenDialog"
      >
        GENERATE PARAMETERS
      </v-btn>
    </v-toolbar>

    <!-- グリッド本体 (仮想スクロール) -->
    <v-card variant="outlined" class="fill-height grid-card">
      <div class="grid-scroll-container virtual-grid-host">
        <VirtualScroll
          ref="virtualScrollRef"
          class="param-grid-virtual"
          direction="both"
          role="grid"
          :items="virtualItems"
          :item-size="rowHeight"
          :column-count="steps"
          :column-width="cellWidth"
          :buffer-before="8"
          :buffer-after="8"
          :sticky-indices="stickyIndices"
          :aria-label="`${title || 'parameter'} grid`"
        >
          <template #item="{ item: row, index: rowIndex, columnRange, offset, getColumnWidth, getCellAriaProps }">
            <div class="param-grid-row" :data-row-index="rowIndex">
              <template v-if="rowIndex === 0">
                <div class="sticky-col head-col header-col top-left-corner" :style="getStickyLeftStyle(offset?.x)">Steps</div>
                <div
                  class="row-cells"
                  :style="{
                    paddingInlineStart: `${columnRange.padStart}px`,
                    paddingInlineEnd: `${columnRange.padEnd}px`
                  }"
                >
                  <div
                    v-for="c in (columnRange.end - columnRange.start)"
                    :key="`h-${columnRange.start + c - 1}`"
                    class="data-col column-header"
                    :class="{ 'selected-header': isColumnSelected(columnRange.start + c - 1) }"
                    :style="{ inlineSize: `${getColumnWidth(columnRange.start + c - 1)}px` }"
                    @mousedown.prevent
                    @click="onColumnHeaderClick(columnRange.start + c - 1, $event)"
                    v-bind="getCellAriaProps(columnRange.start + c - 1)"
                  >
                    {{ columnRange.start + c }}
                  </div>
                </div>
              </template>

              <template v-else>
              <div
                class="sticky-col head-col row-label row-header"
                :class="{ 'selected-header': isRowSelected(rowIndex - 1), 'row-disabled': row.disabled }"
                :style="getStickyLeftStyle(offset?.x)"
                @mousedown.prevent
                @click="onRowHeaderClick(rowIndex - 1, $event)"
              >
                <span>
                  {{ row.shortName || row.name }}
                  <v-tooltip
                    v-if="row.help"
                    activator="parent"
                    location="end"
                  >
                    <div style="max-width: 340px;" class="text-body-2">
                      <div class="mt-1"> {{ row.name }}</div>
                      <div class="mt-1"> {{ row.help.overview }}</div>
                      <div><b>範囲:</b> {{ row.help.range }}</div>
                      <div class="mt-1"> {{ row.help.atMin }}</div>
                      <div class="mt-1"> {{ row.help.atMax }}</div>
                    </div>
                  </v-tooltip>
                </span>
              </div>

              <div
                class="row-cells"
                :style="{
                  paddingInlineStart: `${columnRange.padStart}px`,
                  paddingInlineEnd: `${columnRange.padEnd}px`
                }"
              >
                <div
                  v-for="c in (columnRange.end - columnRange.start)"
                  :key="`r-${rowIndex - 1}-c-${columnRange.start + c - 1}`"
                  class="data-col"
                  :class="{ 'selected-cell': isRowSelected(rowIndex - 1) || isColumnSelected(columnRange.start + c - 1) }"
                  :style="{ inlineSize: `${getColumnWidth(columnRange.start + c - 1)}px` }"
                  :data-col-index="columnRange.start + c - 1"
                  v-bind="getCellAriaProps(columnRange.start + c - 1)"
                >
                  <GridCell
                    class="grid-input"
                    :model-value="row.data[columnRange.start + c - 1]"
                    :rowIndex="rowIndex - 1"
                    :colIndex="columnRange.start + c - 1"
                    :selected="isRowSelected(rowIndex - 1) || isColumnSelected(columnRange.start + c - 1)"
                    :disabled="Boolean(row.disabled)"
                    :config="row.config"
                    @update:model-value="onVirtualUpdateCell(rowIndex - 1, columnRange.start + c - 1, $event)"
                    @focus="onCellFocus"
                    @dblclick="onCellDblClick"
                    @paste="onCellPaste"
                  />
                </div>
              </div>
              </template>
            </div>
          </template>
        </VirtualScroll>
      </div>
    </v-card>

    <!-- パラメータ生成ダイアログ -->
    <ParamGenDialog
      v-model="paramGenDialog"
      :initialParams="paramGenInit"
      @apply="applyGeneratedParams"
    />
  </div>
</template>

<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, ref, watch } from 'vue'
import { VirtualScroll } from '@pdanpdan/virtual-scroll'
import '@pdanpdan/virtual-scroll/style.css'
import GridCell from './GridCell.vue'
import ParamGenDialog from './ParamGenDialog.vue'
import {
  getStructuredClipboard,
  setStructuredClipboard,
  type GridCellValue,
  type GridStructuredClipboard,
  type GridStructuredClipboardType
} from './gridClipboard'

// 行データの型
type GridConfig = {
  min: number;
  max: number;
  step?: number;
  isInt?: boolean;
  inputMode?: 'number' | 'note-array';
}

type GridRowData = {
  name: string;
  shortName?: string;
  data: GridCellValue[];
  config: GridConfig;
  disabled?: boolean;
}

type RangeSelection = {
  start: number;
  end: number;
  anchor: number;
}

const props = defineProps({
  title: { type: String, default: '' },
  rows: { type: Array as () => GridRowData[], required: true },
  steps: { type: Number, required: true },
  showRowsLength: { type: Boolean, default: true },
  showColsLength: { type: Boolean, default: true },
  showGenerateParametersButton: { type: Boolean, default: true },
  // 初期コンテキスト用: Streams 入力
  showStreamCount: { type: Boolean, default: false },
  streamCount: { type: Number, default: 0 }
})

const emit = defineEmits([
  'update:rows',
  'update:steps',
  'update:streamCount',
  'selected-columns-change'
])

// --- State ---
const wrapperRef = ref<HTMLElement | null>(null)
const virtualScrollRef = ref<any>(null)
const focusedCell = ref<any>(null) // { rowIndex, colIndex, config }
const paramGenDialog = ref(false)
const paramGenInit = ref<any>({})
const stepsDraft = ref(String(props.steps))
const streamCountDraft = ref(String(props.streamCount))
const rowSelection = ref<RangeSelection | null>(null)
const colSelection = ref<RangeSelection | null>(null)
const copiedTooltipVisible = ref(false)
let copiedTooltipTimer: ReturnType<typeof setTimeout> | null = null

const stickyIndices = [0]
const virtualItems = computed(() => [{ __header: true } as const, ...props.rows])

const rowHeight = 30
const cellWidth = 56

const canGenerateParameters = computed(() => Boolean(focusedCell.value) && focusedCell.value?.config?.inputMode !== 'note-array')

watch(
  () => props.steps,
  (v) => { stepsDraft.value = String(v) }
)
watch(
  () => props.streamCount,
  (v) => { streamCountDraft.value = String(v) }
)
watch(
  () => props.rows.length,
  (len) => {
    rowSelection.value = clampSelectionRange(rowSelection.value, len)
    if (focusedCell.value && focusedCell.value.rowIndex >= len) focusedCell.value = null
  }
)
watch(
  () => props.steps,
  (len) => {
    colSelection.value = clampSelectionRange(colSelection.value, len)
    if (focusedCell.value && focusedCell.value.colIndex >= len) focusedCell.value = null
  }
)

onBeforeUnmount(() => {
  if (copiedTooltipTimer !== null) {
    clearTimeout(copiedTooltipTimer)
    copiedTooltipTimer = null
  }
})

const selectedColumnIndexes = computed<number[]>(() => {
  if (!colSelection.value) return []
  const cols: number[] = []
  for (let i = colSelection.value.start; i <= colSelection.value.end; i++) {
    cols.push(i)
  }
  return cols
})

watch(selectedColumnIndexes, (cols) => {
  emit('selected-columns-change', [...cols])
})

const getStickyLeftStyle = (x: unknown) => {
  const offset = typeof x === 'number' && isFinite(x) ? x : 0
  return {
    insetInlineStart: `${-Math.max(0, offset)}px`
  }
}

// --- Methods ---

const makeRangeSelection = (anchor: number, current: number): RangeSelection => ({
  start: Math.min(anchor, current),
  end: Math.max(anchor, current),
  anchor
})

const clampSelectionRange = (
  selection: RangeSelection | null,
  itemCount: number
): RangeSelection | null => {
  if (!selection || itemCount <= 0) return null
  const maxIndex = itemCount - 1
  const start = Math.max(0, Math.min(selection.start, maxIndex))
  const end = Math.max(0, Math.min(selection.end, maxIndex))
  const anchor = Math.max(0, Math.min(selection.anchor, maxIndex))
  return {
    start: Math.min(start, end),
    end: Math.max(start, end),
    anchor
  }
}

const focusWrapper = () => {
  if (!wrapperRef.value) return
  wrapperRef.value.focus({ preventScroll: true })
}

const clearHeaderSelections = () => {
  rowSelection.value = null
  colSelection.value = null
}

const clearAllSelections = () => {
  focusedCell.value = null
  clearHeaderSelections()
}

const isRowSelected = (rowIndex: number): boolean => {
  if (!rowSelection.value) return false
  return rowIndex >= rowSelection.value.start && rowIndex <= rowSelection.value.end
}

const isColumnSelected = (colIndex: number): boolean => {
  if (!colSelection.value) return false
  return colIndex >= colSelection.value.start && colIndex <= colSelection.value.end
}

const showCopiedTooltip = () => {
  copiedTooltipVisible.value = true
  if (copiedTooltipTimer !== null) clearTimeout(copiedTooltipTimer)
  copiedTooltipTimer = setTimeout(() => {
    copiedTooltipVisible.value = false
    copiedTooltipTimer = null
  }, 900)
}

const normalizeClipboardText = (text: string): string =>
  text.replace(/\r\n/g, '\n').replace(/\r/g, '\n').trimEnd()

const matrixToClipboardText = (matrix: GridCellValue[][]): string =>
  matrix.map((row) => row.map((v) => String(v)).join('\t')).join('\n')

const normalizeNoteArrayCellText = (value: unknown): string => {
  const raw = String(value ?? '').trim()
  if (raw === '') return ''

  const hasBracketWrapper = raw.charAt(0) === '[' && raw.charAt(raw.length - 1) === ']'
  const body = hasBracketWrapper ? raw.slice(1, -1) : raw
  const numbers = body
    .split(',')
    .map((part) => part.trim())
    .filter((part) => part.length > 0)
    .map((part) => Number(part))
    .filter((part) => isFinite(part))
    .map((part) => Math.round(part))

  return numbers.length > 0 ? `[${numbers.join(', ')}]` : ''
}

const clampToConfig = (value: number, config: GridConfig): number => {
  let v = value
  if (config.isInt) v = Math.round(v)
  if (v < config.min) v = config.min
  if (v > config.max) v = config.max
  return v
}

const coerceCellValueForConfig = (value: unknown, config: GridConfig): GridCellValue | null => {
  if (config.inputMode === 'note-array') {
    const normalized = normalizeNoteArrayCellText(value)
    return normalized
  }

  const num = Number(value)
  if (!isFinite(num)) return null
  return clampToConfig(num, config)
}

const getRowSelectionMatrix = (): GridCellValue[][] => {
  if (!rowSelection.value) return []
  const matrix: GridCellValue[][] = []
  for (let rowIndex = rowSelection.value.start; rowIndex <= rowSelection.value.end; rowIndex++) {
    const row = props.rows[rowIndex]
    if (!row) continue
    const values: GridCellValue[] = []
    for (let colIndex = 0; colIndex < props.steps; colIndex++) {
      const raw = row.data[colIndex]
      if (row.config.inputMode === 'note-array') values.push(String(raw ?? ''))
      else {
        const num = Number(raw ?? 0)
        values.push(isFinite(num) ? num : 0)
      }
    }
    matrix.push(values)
  }
  return matrix
}

const getColSelectionMatrix = (): GridCellValue[][] => {
  if (!colSelection.value) return []
  const selectedCols = selectedColumnIndexes.value
  return props.rows.map((row) =>
    selectedCols.map((colIndex) => {
      const raw = row.data[colIndex]
      if (row.config.inputMode === 'note-array') return String(raw ?? '')
      const num = Number(raw ?? 0)
      return isFinite(num) ? num : 0
    })
  )
}

const applyRowPaste = (clipboard: GridStructuredClipboard) => {
  if (!rowSelection.value) return

  const matrix = clipboard.matrix
  if (!Array.isArray(matrix) || matrix.length === 0) return

  const startRow = rowSelection.value.start
  const newRows = [...props.rows]
  let changed = false

  for (let srcRow = 0; srcRow < matrix.length; srcRow++) {
    const dstRowIndex = startRow + srcRow
    if (dstRowIndex >= newRows.length) break

    const sourceValues = matrix[srcRow]
    if (!Array.isArray(sourceValues) || sourceValues.length === 0) continue

    const targetRow = { ...newRows[dstRowIndex] }
    const newData = [...targetRow.data]

    while (newData.length < props.steps) newData.push(targetRow.config.inputMode === 'note-array' ? '' : 0)

    const copyCols = Math.min(sourceValues.length, props.steps)
    for (let colIndex = 0; colIndex < copyCols; colIndex++) {
      const coerced = coerceCellValueForConfig(sourceValues[colIndex], targetRow.config)
      if (coerced == null) continue
      newData[colIndex] = coerced
      changed = true
    }

    targetRow.data = newData
    newRows[dstRowIndex] = targetRow
  }

  if (changed) emit('update:rows', newRows)
}

const applyColPaste = (clipboard: GridStructuredClipboard) => {
  if (!colSelection.value) return

  const matrix = clipboard.matrix
  if (!Array.isArray(matrix) || matrix.length === 0) return

  const startCol = colSelection.value.start
  const sourceWidth = matrix.reduce((max, row) => Math.max(max, Array.isArray(row) ? row.length : 0), 0)
  if (sourceWidth <= 0) return

  const requiredLen = startCol + sourceWidth
  if (requiredLen > props.steps) emit('update:steps', requiredLen)

  const newRows = [...props.rows]
  let changed = false
  const copyRows = Math.min(matrix.length, newRows.length)

  for (let rowIndex = 0; rowIndex < copyRows; rowIndex++) {
    const sourceValues = matrix[rowIndex]
    if (!Array.isArray(sourceValues) || sourceValues.length === 0) continue

    const targetRow = { ...newRows[rowIndex] }
    const newData = [...targetRow.data]

    while (newData.length < requiredLen) newData.push(targetRow.config.inputMode === 'note-array' ? '' : 0)

    for (let colOffset = 0; colOffset < sourceValues.length; colOffset++) {
      const coerced = coerceCellValueForConfig(sourceValues[colOffset], targetRow.config)
      if (coerced == null) continue
      const dstColIndex = startCol + colOffset
      newData[dstColIndex] = coerced
      changed = true
    }

    targetRow.data = newData
    newRows[rowIndex] = targetRow
  }

  if (changed) emit('update:rows', newRows)
}

// Steps 入力変更
const onStepsInput = (e: Event) => {
  const target = e.target as HTMLInputElement
  stepsDraft.value = target.value
}

const onStepsBlur = (e: Event) => {
  const target = e.target as HTMLInputElement
  const raw = target.value.trim()
  if (raw === '') {
    stepsDraft.value = String(props.steps)
    target.value = stepsDraft.value
    return
  }

  const v = parseInt(raw, 10)
  if (Number.isNaN(v) || v < 1) {
    stepsDraft.value = String(props.steps)
    target.value = stepsDraft.value
    return
  }
  if (v !== props.steps) emit('update:steps', v)
  stepsDraft.value = String(v)
  target.value = stepsDraft.value
}

// Streams 入力変更
const onStreamInput = (e: Event) => {
  const target = e.target as HTMLInputElement
  streamCountDraft.value = target.value
}

const onStreamBlur = (e: Event) => {
  const target = e.target as HTMLInputElement
  const raw = target.value.trim()
  if (raw === '') {
    streamCountDraft.value = String(props.streamCount)
    target.value = streamCountDraft.value
    return
  }

  const v = parseInt(raw, 10)
  if (Number.isNaN(v) || v < 1) {
    streamCountDraft.value = String(props.streamCount)
    target.value = streamCountDraft.value
    return
  }
  if (v !== props.streamCount) emit('update:streamCount', v)
  streamCountDraft.value = String(v)
  target.value = streamCountDraft.value
}

const onRowHeaderClick = (rowIndex: number, event: MouseEvent) => {
  const shiftKey = event.shiftKey
  if (rowIndex < 0 || rowIndex >= props.rows.length) return

  const anchor = shiftKey && rowSelection.value ? rowSelection.value.anchor : rowIndex
  rowSelection.value = makeRangeSelection(anchor, rowIndex)
  colSelection.value = null
  focusedCell.value = null
  focusWrapper()
}

const onVirtualUpdateCell = (rowIndex: number, colIndex: number, val: GridCellValue) => {
  const row = props.rows[rowIndex]
  if (!row || row.disabled) return

  const nextRow = { ...row }
  const newData = [...nextRow.data]
  while (newData.length <= colIndex) newData.push(nextRow.config?.inputMode === 'note-array' ? '' : 0)
  newData[colIndex] = val
  nextRow.data = newData
  updateRow(rowIndex, nextRow)
}

const onColumnHeaderClick = (colIndex: number, event: MouseEvent) => {
  if (colIndex < 0 || colIndex >= props.steps) return

  const anchor = event.shiftKey && colSelection.value ? colSelection.value.anchor : colIndex
  colSelection.value = makeRangeSelection(anchor, colIndex)
  rowSelection.value = null
  focusedCell.value = null
  focusWrapper()
}

const onWrapperCopy = (event: ClipboardEvent) => {
  const target = event.target as HTMLElement | null
  const isGridTarget = target === wrapperRef.value || !!target?.closest('.virtual-grid-host')
  if (!isGridTarget) {
    setStructuredClipboard(null)
    return
  }

  let type: GridStructuredClipboardType | null = null
  let matrix: number[][] = []

  if (rowSelection.value) {
    type = 'rows'
    matrix = getRowSelectionMatrix()
  } else if (colSelection.value) {
    type = 'cols'
    matrix = getColSelectionMatrix()
  } else {
    setStructuredClipboard(null)
    return
  }

  if (!type || matrix.length === 0) return

  const text = matrixToClipboardText(matrix)
  if (!text) return

  event.preventDefault()
  if (event.clipboardData) {
    event.clipboardData.setData('text/plain', text)
  } else if (navigator.clipboard) {
    void navigator.clipboard.writeText(text).catch(() => {})
  }

  setStructuredClipboard({
    type,
    matrix,
    text: normalizeClipboardText(text)
  })
  showCopiedTooltip()
}

const onWrapperPaste = (event: ClipboardEvent) => {
  if (!rowSelection.value && !colSelection.value) return

  const target = event.target as HTMLElement | null
  const isGridTarget = target === wrapperRef.value || !!target?.closest('.virtual-grid-host')
  if (!isGridTarget) return

  const clipboard = getStructuredClipboard()
  if (!clipboard) return

  const incomingText = normalizeClipboardText(event.clipboardData?.getData('text') ?? '')
  if (incomingText !== clipboard.text) {
    setStructuredClipboard(null)
    return
  }

  if (clipboard.type === 'rows') {
    event.preventDefault()
    if (!rowSelection.value) return
    applyRowPaste(clipboard)
    return
  }

  event.preventDefault()
  if (!colSelection.value) return
  applyColPaste(clipboard)
}

// フォーカスアウト時: コンポーネント外に出たら選択解除
const onFocusOut = (event: FocusEvent) => {
  if (paramGenDialog.value) return

  const relatedTarget = event.relatedTarget as HTMLElement | null
  if (relatedTarget && wrapperRef.value && wrapperRef.value.contains(relatedTarget)) {
    return
  }
  clearAllSelections()
}

// 行更新
const updateRow = (index: number, newRow: GridRowData) => {
  const newRows = [...props.rows]
  newRows[index] = newRow
  emit('update:rows', newRows)
}

// 行数変更（汎用用）
const updateRowCount = (e: Event) => {
  const target = e.target as HTMLInputElement
  const newCount = parseInt(target.value)
  if (isNaN(newCount) || newCount < 1) return

  const currentRows = [...props.rows]

  if (newCount > currentRows.length) {
    while (currentRows.length < newCount) {
      currentRows.push({
        name: `Param ${currentRows.length + 1}`,
        data: Array(props.steps).fill(0),
        config: { min: 0, max: 1, isInt: false, step: 0.1 }
      })
    }
  } else if (newCount < currentRows.length) {
    currentRows.splice(newCount)
  }

  emit('update:rows', currentRows)
}

// フォーカス
const onCellFocus = (payload: any) => {
  focusedCell.value = payload
  clearHeaderSelections()
}

// ダブルクリックで即 ParamGen を開く
const onCellDblClick = (payload: any) => {
  openParamGenDialogAt(payload)
}

// ペースト
const onCellPaste = (payload: any) => {
  const clipboard = getStructuredClipboard()
  const incomingText = normalizeClipboardText(payload.text ?? '')
  if (clipboard) {
    if (incomingText === clipboard.text) return
    setStructuredClipboard(null)
  }

  const { text, rowIndex, colIndex, config } = payload
  const targetRow = { ...props.rows[rowIndex] }

  if (config.inputMode === 'note-array') {
    const newData = [...targetRow.data]
    while (newData.length <= colIndex) newData.push('')
    newData[colIndex] = normalizeNoteArrayCellText(text)
    targetRow.data = newData
    updateRow(rowIndex, targetRow)
    return
  }

  const values = text.split(/[\s\t]+/).filter((v: string) => v !== '').map(Number)
  if (values.some(isNaN)) return

  const requiredLen = colIndex + values.length

  // 列数の自動拡張
  if (requiredLen > props.steps) emit('update:steps', requiredLen)

  const newData = [...targetRow.data]
  while (newData.length < requiredLen) newData.push(0)

  values.forEach((val: number, k: number) => {
    let v = val
    if (config.isInt) v = Math.round(v)
    if (v < config.min) v = config.min
    if (v > config.max) v = config.max
    newData[colIndex + k] = v
  })

  targetRow.data = newData
  updateRow(rowIndex, targetRow)
}

const openParamGenDialogAt = (cell: any) => {
  if (!cell) return
  if (cell.config?.inputMode === 'note-array') return
  focusedCell.value = cell
  clearHeaderSelections()

  const { rowIndex, colIndex, config } = cell
  const currentVal = props.rows[rowIndex].data[colIndex] ?? 0

  paramGenInit.value = {
    steps: Math.max(1, props.steps - colIndex),
    start: currentVal,
    end: config.max,
    randMin: config.min,
    randMax: config.max,
    mode: 'transition',
    curve: 'linear'
  }

  paramGenDialog.value = true
}

// ParamGen ダイアログオープン
const openParamGenDialog = () => {
  if (!canGenerateParameters.value) return
  openParamGenDialogAt(focusedCell.value)
}

const getInputAt = (rowIndex: number, colIndex: number): HTMLInputElement | null => {
  const root = wrapperRef.value
  if (!root) return null
  const rowEl = root.querySelector(`[data-row-index="${rowIndex}"]`) as HTMLElement | null
  if (!rowEl) return null
  return rowEl.querySelector(`[data-col-index="${colIndex}"] input.grid-input`) as HTMLInputElement | null
}

const focusCellAndScroll = async (rowIndex: number, colIndex: number, config: any) => {
  virtualScrollRef.value?.scrollToIndex?.(rowIndex, colIndex, { align: { y: 'auto', x: 'auto' }, behavior: 'auto' })
  await nextTick()
  await nextTick()
  const input = getInputAt(rowIndex, colIndex)
  if (!input) return
  input.scrollIntoView({ block: 'nearest', inline: 'nearest', behavior: 'auto' })
  input.focus()
  if (typeof input.select === 'function') input.select()
  focusedCell.value = { rowIndex, colIndex, config }
  clearHeaderSelections()
}

// 生成データ適用
const applyGeneratedParams = async (params: any) => {
  if (!focusedCell.value) return
  const { steps, mode, start, end, curve, randMin, randMax } = params
  const { rowIndex, colIndex, config } = focusedCell.value

  const requiredLen = colIndex + steps
  if (requiredLen > props.steps) emit('update:steps', requiredLen)

  const targetRow = { ...props.rows[rowIndex] }
  const newData = [...targetRow.data]
  while (newData.length < requiredLen) newData.push(0)

  for (let i = 0; i < steps; i++) {
    let val = 0
    if (mode === 'transition') {
      const t = steps > 1 ? i / (steps - 1) : 1
      let easedT = t
      if (curve === 'easeInQuad') easedT = t * t
      if (curve === 'easeOutQuad') easedT = t * (2 - t)
      if (curve === 'easeInOutQuad') {
        easedT = t < 0.5 ? 2 * t * t : -1 + (4 - 2 * t) * t
      }
      val = start + (end - start) * easedT
    } else {
      val = randMin + Math.random() * (randMax - randMin)
    }

    if (config.isInt) val = Math.round(val)
    else val = Number(val.toFixed(2))

    if (val < config.min) val = config.min
    if (val > config.max) val = config.max

    newData[colIndex + i] = val
  }

  targetRow.data = newData
  updateRow(rowIndex, targetRow)
  paramGenDialog.value = false

  const nextColIndex = colIndex + steps
  const currentMaxSteps = Math.max(props.steps, requiredLen)
  if (nextColIndex >= currentMaxSteps) return
  await focusCellAndScroll(rowIndex, nextColIndex, config)
}
</script>

<style scoped>
.grid-wrapper {
  display: flex;
  flex-direction: column;
  height: 100%;
  min-height: 0;
  overflow: hidden;
  outline: none;
}
.sticky-toolbar {
  position: sticky;
  top: 0;
  z-index: 20;
}
.step-input {
  width: 60px;
  border: 1px solid #ccc;
  padding: 2px 5px;
  border-radius: 4px;
  background: white;
}
.copy-tooltip-anchor {
  display: inline-block;
  width: 1px;
  height: 1px;
}
.grid-card {
  display: flex;
  flex-direction: column;
  flex: 1 1 auto;
  min-height: 0;
  overflow: hidden;
}
.grid-scroll-container {
  overflow: hidden;
  flex: 1 1 auto;
  min-height: 0;
}
.param-grid-virtual {
  width: 100%;
  height: 100%;
  font-size: 0.8rem;
}
.param-grid-header {
  display: flex;
  height: 40px;
  background-color: #f5f5f5;
}
.header-cols {
  display: flex;
  flex: 1;
}
.header-col {
  background-color: #f5f5f5;
  display: flex;
  align-items: center;
  z-index: 6;
}
.param-grid-row {
  display: flex;
  min-height: 30px;
  background-color: #fff;
}
.param-grid-row:first-child {
  background-color: #f5f5f5;
}
.row-cells {
  display: flex;
  flex: 1;
}
.data-col {
  box-sizing: border-box;
  min-width: 56px;
  max-width: 56px;
  width: 56px;
  border-right: 1px solid #e0e0e0;
  border-bottom: 1px solid #e0e0e0;
  display: flex;
  align-items: stretch;
}
.column-header {
  background-color: #f5f5f5;
  user-select: none;
  cursor: pointer;
  align-items: center;
  justify-content: center;
  font-weight: 600;
  z-index: 5;
}
.top-left-corner {
  z-index: 12 !important;
  background-color: #f5f5f5;
}
.sticky-col {
  position: sticky;
  left: 0;
  z-index: 4;
  background-color: white;
  border-right: 2px solid #ccc;
  border: 1px solid #e0e0e0;
}
.head-col {
  width: 120px !important;
  min-width: 120px !important;
  max-width: 120px !important;
  font-weight: bold;
  text-align: left;
  padding-left: 8px;
}
.row-label {
  vertical-align: middle;
}
.row-header {
  user-select: none;
  cursor: pointer;
}
.selected-header {
  background-color: #e8f5e9 !important;
  font-weight: bold;
}
.selected-cell {
  background-color: #e8f5e9;
}
.row-disabled {
  color: #9e9e9e;
}
</style>
