<template>
  <!-- フォーカス監視ラッパ -->
  <div class="grid-wrapper" ref="wrapperRef" @focusout="onFocusOut">
    <!-- ツールバー -->
    <v-toolbar density="compact" color="grey-lighten-4" class="px-2 mb-2 rounded">
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
          :value="streamCount"
          @input="onStreamInput"
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
          :value="steps"
          @input="$emit('update:steps', parseInt(($event.target as HTMLInputElement).value))"
          min="1"
          max="200"
          class="step-input mr-1"
        >
      </div>

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
                class="data-col"
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
              @update:row="updateRow(idx, $event)"
              @focus-cell="onCellFocus"
              @paste-cell="onCellPaste"
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
import { ref } from 'vue'
import GridRow from './GridRow.vue'
import ParamGenDialog from './ParamGenDialog.vue'

// 行データの型
type GridRowData = {
  name: string;
  data: number[];
  config: {
    min: number;
    max: number;
    step?: number;
    isInt?: boolean;
  }
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

// --- Methods ---

// Streams 入力変更
const onStreamInput = (e: Event) => {
  const target = e.target as HTMLInputElement
  const v = parseInt(target.value)
  if (isNaN(v) || v < 1) return
  emit('update:streamCount', v)
}

// フォーカスアウト時: コンポーネント外に出たら選択解除
const onFocusOut = (event: FocusEvent) => {
  if (paramGenDialog.value) return

  const relatedTarget = event.relatedTarget as HTMLElement | null
  if (relatedTarget && wrapperRef.value && wrapperRef.value.contains(relatedTarget)) {
    return
  }
  focusedCell.value = null
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
}

// ペースト
const onCellPaste = (payload: any) => {
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

// ParamGen ダイアログオープン
const openParamGenDialog = () => {
  if (!focusedCell.value) return

  const { rowIndex, colIndex, config } = focusedCell.value
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

// 生成データ適用
const applyGeneratedParams = (params: any) => {
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
}
</script>

<style scoped>
.grid-wrapper {
  display: flex;
  flex-direction: column;
  height: 100%;
}
.step-input {
  width: 60px;
  border: 1px solid #ccc;
  padding: 2px 5px;
  border-radius: 4px;
  background: white;
}
.grid-card {
  overflow: hidden;
  display: flex;
  flex-direction: column;
}
.grid-scroll-container {
  overflow: auto;
  flex-grow: 1;
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
</style>
