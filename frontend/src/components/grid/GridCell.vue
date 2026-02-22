<template>
  <input
    type="number"
    class="grid-input"
    :class="{ 'is-selected': selected }"
    :value="modelValue"
    :min="config.min"
    :max="config.max"
    :step="config.step || (config.isInt ? 1 : 0.1)"
    @input="onInput"
    @focus="onFocus"
    @dblclick="onDblClick"
    @paste="onPaste"
  >
</template>

<script setup lang="ts">
const props = defineProps({
  modelValue: { type: [Number, String], default: 0 },
  rowIndex: { type: Number, required: true },
  colIndex: { type: Number, required: true },
  selected: { type: Boolean, default: false },
  config: {
    type: Object,
    default: () => ({ min: 0, max: 1, isInt: false, step: 0.1 })
  }
})

const emit = defineEmits(['update:modelValue', 'focus', 'dblclick', 'paste'])

const onInput = (e: Event) => {
  const target = e.target as HTMLInputElement
  let val = parseFloat(target.value)
  if (isNaN(val)) val = 0
  emit('update:modelValue', val)
}

const onFocus = () => {
  emit('focus', {
    rowIndex: props.rowIndex,
    colIndex: props.colIndex,
    config: props.config
  })
}

const onDblClick = () => {
  emit('dblclick', {
    rowIndex: props.rowIndex,
    colIndex: props.colIndex,
    config: props.config
  })
}

const onPaste = (e: ClipboardEvent) => {
  // デフォルトの貼り付け動作を防止してカスタム処理へ
  // (ただしInput要素への直接ペーストも許容する場合は preventDefault しない設計もありだが、
  //  ここでは複数セルへの展開を行うため preventDefault するのが一般的)
  e.preventDefault()

  const text = e.clipboardData?.getData('text')
  if (text) {
    emit('paste', {
      text,
      rowIndex: props.rowIndex,
      colIndex: props.colIndex,
      config: props.config
    })
  }
}
</script>

<style scoped>
.grid-input {
  width: 100%;
  height: 100%;
  border: none;
  text-align: center;
  background: transparent;
  outline: none;
  font-size: 0.9rem;
}
.grid-input:focus {
  background-color: #e8f5e9;
  font-weight: bold;
}
.grid-input.is-selected {
  background-color: #e8f5e9;
  font-weight: bold;
}
</style>
