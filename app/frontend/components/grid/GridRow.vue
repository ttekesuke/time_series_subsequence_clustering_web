<template>
  <tr>
    <!-- 固定ヘッダー列 (パラメータ名) -->
    <td class="sticky-col head-col row-label">
      <span>
        {{ row.shortName }}
        <v-tooltip
          v-if="row.help"
          activator="parent"
          location="end"
        >
          <div style="max-width: 340px;" class="text-body-2">
            <div class="mt-1"> {{ row.help.overview }}</div>
            <div><b>範囲:</b> {{ row.help.range }}</div>
            <div class="mt-1"> {{ row.help.atMin }}</div>
            <div class="mt-1"> {{ row.help.atMax }}</div>
          </div>
        </v-tooltip>
      </span>
    </td>

    <!-- データ列 -->
    <td v-for="i in steps" :key="i" class="data-col">
      <GridCell
        :model-value="row.data[i-1]"
        @update:model-value="updateCell(i-1, $event)"
        :rowIndex="rowIndex"
        :colIndex="i-1"
        :config="row.config"
        @focus="$emit('focus-cell', $event)"
        @paste="$emit('paste-cell', $event)"
      />
    </td>
  </tr>
</template>

<script setup lang="ts">
import GridCell from './GridCell.vue'

const props = defineProps({
  row: {
    type: Object,
    required: true
    // { name: string, data: number[], config: { min, max, isInt... } }
  },
  rowIndex: { type: Number, required: true },
  steps: { type: Number, required: true }
})

const emit = defineEmits(['update:row', 'focus-cell', 'paste-cell'])

const updateCell = (idx: number, val: number) => {
  // 配列の特定要素だけ更新するため、コピーして置換
  // (Vueのバージョンによっては直接代入でも検知するが安全のため)
  const newData = [...props.row.data]
  // 配列が足りない場合は埋める
  while(newData.length <= idx) newData.push(0)

  newData[idx] = val

  // 行データ全体を更新通知
  emit('update:row', { ...props.row, data: newData })
}
</script>

<style scoped>
td {
  border: 1px solid #e0e0e0;
  padding: 2px;
  text-align: center;
  width: 3.5rem;
  min-width: 3.5rem;
  max-width: 3.5rem;
  box-sizing: border-box;
  height: 1.5rem;
}

/* Sticky Columns */
.sticky-col {
  position: sticky;
  z-index: 2;
  background-color: white;
}
.head-col {
  left: 0;
  z-index: 3;
  width: 120px !important;
  min-width: 120px !important;
  max-width: 120px !important;
  font-weight: bold;
  text-align: left !important;
}
.row-label {
  padding-left: 8px !important;
  vertical-align: middle;
}
</style>
