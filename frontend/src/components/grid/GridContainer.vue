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
        color="secondary"
        size="small"
        :disabled="!focusedCell"
        @click="openParamGenDialog"
      >
        GENERATE PARAMETERS
      </v-btn>
    </v-toolbar>

    <!-- グリッド本体 -->
    <v-card variant="outlined" class="fill-height grid-card">
      <div class="grid-scroll-container">
        <table class="param-grid">
          <thead>
            <tr>
              <th class="sticky-col head-col">Steps</th>
              <th
                v-for="i in steps"
                :key="`h-${i}`"
                class="data-col column-header"
                :class="{ 'selected-header': isColumnSelected(i - 1) }"
                @mousedown.prevent
                @click="onColumnHeaderClick(i - 1, $event)"
              >
                {{ i }}
              </th>
            </tr>
          </thead>
          <tbody>
            <GridRow
              v-for="(row, idx) in rows"
              :key="`row-${idx}`"
              :row="row"
              :rowIndex="idx"
              :steps="steps"
              :rowSelected="isRowSelected(idx)"
              :selectedCols="selectedColumnIndexes"
              @update:row="updateRow(idx, $event)"
              @focus-cell="onCellFocus"
              @dblclick-cell="onCellDblClick"
              @paste-cell="onCellPaste"
              @select-row-header="onRowHeaderSelect"
            />
          </tbody>
        </table>
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
import GridRow from './GridRow.vue'
import ParamGenDialog from './ParamGenDialog.vue'
import {
  getStructuredClipboard,
  setStructuredClipboard,
  type GridStructuredClipboard,
  type GridStructuredClipboardType
} from './gridClipboard'

// 行データの型
type GridConfig = {
  min: number;
  max: number;
  step?: number;
  isInt?: boolean;
}

type GridRowData = {
  name: string;
  shortName?: string;
  data: number[];
  config: GridConfig;
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
  // 初期コンテキスト用: Streams 入力
  showStreamCount: { type: Boolean, default: false },
  streamCount: { type: Number, default: 0 }
})

const emit = defineEmits([
  'update:rows',
  'update:steps',
  'update:streamCount'
])

// --- State ---
const wrapperRef = ref<HTMLElement | null>(null)
const focusedCell = ref<any>(null) // { rowIndex, colIndex, config }
const paramGenDialog = ref(false)
const paramGenInit = ref<any>({})
const stepsDraft = ref(String(props.steps))
const streamCountDraft = ref(String(props.streamCount))
const rowSelection = ref<RangeSelection | null>(null)
const colSelection = ref<RangeSelection | null>(null)
const copiedTooltipVisible = ref(false)
let copiedTooltipTimer: ReturnType<typeof setTimeout> | null = null

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

const matrixToClipboardText = (matrix: number[][]): string =>
  matrix.map((row) => row.map((v) => String(v)).join('\t')).join('\n')

const clampToConfig = (value: number, config: GridConfig): number => {
  let v = value
  if (config.isInt) v = Math.round(v)
  if (v < config.min) v = config.min
  if (v > config.max) v = config.max
  return v
}

const getRowSelectionMatrix = (): number[][] => {
  if (!rowSelection.value) return []
  const matrix: number[][] = []
  for (let rowIndex = rowSelection.value.start; rowIndex <= rowSelection.value.end; rowIndex++) {
    const row = props.rows[rowIndex]
    if (!row) continue
    const values: number[] = []
    for (let colIndex = 0; colIndex < props.steps; colIndex++) {
      const raw = Number(row.data[colIndex] ?? 0)
      values.push(Number.isFinite(raw) ? raw : 0)
    }
    matrix.push(values)
  }
  return matrix
}

const getColSelectionMatrix = (): number[][] => {
  if (!colSelection.value) return []
  const selectedCols = selectedColumnIndexes.value
  return props.rows.map((row) =>
    selectedCols.map((colIndex) => {
      const raw = Number(row.data[colIndex] ?? 0)
      return Number.isFinite(raw) ? raw : 0
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

    while (newData.length < props.steps) newData.push(0)

    const copyCols = Math.min(sourceValues.length, props.steps)
    for (let colIndex = 0; colIndex < copyCols; colIndex++) {
      const raw = Number(sourceValues[colIndex])
      if (!Number.isFinite(raw)) continue
      newData[colIndex] = clampToConfig(raw, targetRow.config)
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

    while (newData.length < requiredLen) newData.push(0)

    for (let colOffset = 0; colOffset < sourceValues.length; colOffset++) {
      const raw = Number(sourceValues[colOffset])
      if (!Number.isFinite(raw)) continue
      const dstColIndex = startCol + colOffset
      newData[dstColIndex] = clampToConfig(raw, targetRow.config)
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

const onRowHeaderSelect = (payload: { rowIndex: number; shiftKey: boolean }) => {
  const { rowIndex, shiftKey } = payload
  if (rowIndex < 0 || rowIndex >= props.rows.length) return

  const anchor = shiftKey && rowSelection.value ? rowSelection.value.anchor : rowIndex
  rowSelection.value = makeRangeSelection(anchor, rowIndex)
  colSelection.value = null
  focusedCell.value = null
  focusWrapper()
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
  const isGridTarget = target === wrapperRef.value || !!target?.closest('.param-grid')
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
  const isGridTarget = target === wrapperRef.value || !!target?.closest('.param-grid')
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
  const values = text.split(/[\s\t]+/).filter((v: string) => v !== '').map(Number)
  if (values.some(isNaN)) return

  const requiredLen = colIndex + values.length

  // 列数の自動拡張
  if (requiredLen > props.steps) emit('update:steps', requiredLen)

  const targetRow = { ...props.rows[rowIndex] }
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
  if (!focusedCell.value) return
  openParamGenDialogAt(focusedCell.value)
}

const getInputAt = (rowIndex: number, colIndex: number): HTMLInputElement | null => {
  const root = wrapperRef.value
  if (!root) return null
  const rows = root.querySelectorAll('.param-grid tbody tr')
  const rowEl = rows.item(rowIndex) as HTMLElement | null
  if (!rowEl) return null
  const inputs = rowEl.querySelectorAll('td.data-col input.grid-input')
  return (inputs.item(colIndex) as HTMLInputElement | null) ?? null
}

const focusCellAndScroll = async (rowIndex: number, colIndex: number, config: any) => {
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
  overflow-x: auto;
  overflow-y: auto;
  flex: 1 1 auto;
  min-height: 0;
}
.param-grid {
  border-collapse: separate;
  border-spacing: 0;
  table-layout: fixed;
  font-size: 0.8rem;
}
.param-grid th {
  background-color: #f5f5f5;
  position: sticky;
  top: 0;
  z-index: 2;
  height: 40px;
  border: 1px solid #e0e0e0;
}
.sticky-col {
  position: sticky;
  left: 0;
  z-index: 3;
  background-color: white;
  border-right: 2px solid #ccc;
}
thead th.sticky-col {
  z-index: 4;
}
.column-header {
  cursor: pointer;
  user-select: none;
}
.selected-header {
  background-color: #e8f5e9 !important;
  font-weight: bold;
}
</style>
