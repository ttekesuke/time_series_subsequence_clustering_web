<template>
  <div class="roll-container">
    <!-- スクロールエリア -->
    <div class="scroll-wrapper" ref="scrollWrapper" @scroll="onScroll">
      <canvas ref="canvas" :height="height"></canvas>
    </div>
  </div>
</template>

<script setup lang="ts">
import { ref, onMounted, watch, computed, nextTick } from 'vue'

const props = defineProps({
  // 配列の配列、またはカンマ区切り文字列の配列を受け取るため型定義を緩めます
  streamValues: { type: [Array, Object], required: true },
  streamVelocities: { type: [Array, Object], required: false, default: () => [] },
  minValue: { type: Number, default: 0 },
  maxValue: { type: Number, default: 127 },
  stepWidth: { type: Number, default: 10 },
  height: { type: Number, default: null },
  highlightIndices: { type: Array as () => number[], default: () => [] },
  highlightWindowSize: { type: Number, default: 0 },
  valueResolution: { type: Number, default: 1 }
})

const emit = defineEmits(['scroll'])
const scrollWrapper = ref<HTMLElement | null>(null)
const canvas = ref<HTMLCanvasElement | null>(null)

const onScroll = (e: Event) => {
  emit('scroll', e)
}

const draw = () => {
  if (!canvas.value || !scrollWrapper.value) return
  const ctx = canvas.value.getContext('2d')
  if (!ctx) return

  const values = props.streamValues
  const velocities = props.streamVelocities

  // データ量に応じた幅設定
  const maxStep = Math.max(0, ...values.map(s => s.length))

  // 描画幅の計算: 親から渡された stepWidth を使用
  // 最低でもラッパー幅は確保して背景を描画する
  const wrapperWidth = scrollWrapper.value.clientWidth
  const contentWidth = maxStep * props.stepWidth
  const width = Math.max(wrapperWidth, contentWidth)
  // determine canvas height: prefer explicit prop.height, otherwise use wrapper height
  const baseCanvasHeight = (props.height && props.height > 0) ? props.height : (scrollWrapper.value.clientHeight || 200)

  // 値の描画に必要な高さを計算してキャンバスの高さを確定する
  const valueRange = (props.maxValue - props.minValue) + 1
  const steps = Math.max(
    1,
    Math.floor((props.maxValue - props.minValue) / props.valueResolution) + 1
  )

  const minSlotHeight = 4
  let slotHeight = Math.floor(baseCanvasHeight / steps)
  let actualPlotHeight = baseCanvasHeight
  if (slotHeight < minSlotHeight) {
    slotHeight = minSlotHeight
    actualPlotHeight = slotHeight * steps
  }
  canvas.value.width = width
  canvas.value.height = actualPlotHeight
  const canvasHeight = actualPlotHeight

  // 背景クリア
  ctx.fillStyle = '#f9f9f9'
  ctx.fillRect(0, 0, width, canvasHeight)

  // グリッド線 (先に描画しておく)
  ctx.strokeStyle = '#eeeeee'
  ctx.lineWidth = 1
  for (let i = 0; i <= maxStep; i++) {
    const x = i * props.stepWidth
    ctx.beginPath()
    ctx.moveTo(x, 0)
    ctx.lineTo(x, canvasHeight)
    ctx.stroke()
  }

  values.forEach((stream, sIdx) => {

    // ストリームごとの色 (HSLで分散)
    const hue = (sIdx * 137.5) % 360
    const baseColor = `hsla(${hue}, 70%, 45%, 1)`

    stream.forEach((val, step) => {
      if (val === null || val === undefined || isNaN(Number(val))) return

      // Y座標計算 (整数値ごとのスロットを上から割り当てる)
      const clampedVal = Math.max(props.minValue, Math.min(props.maxValue, Number(val)))

      // ★ 値 → 0〜(steps-1) のインデックスに変換
      const normalizedIndex = Math.round(
        (clampedVal - props.minValue) / props.valueResolution
      )
      // 上が最大値になるように反転
      const slotIndex = (steps - 1) - normalizedIndex
      const y = slotIndex * slotHeight + (slotHeight / 2)

      // X座標: 親から渡された stepWidth に従う
      const x = step * props.stepWidth

      // 濃淡 (Velocity)
      let alpha = 0.8 // デフォルト少し濃くして視認性向上
      if (velocities[sIdx] && velocities[sIdx][step] !== undefined) {
        const vel = Number(velocities[sIdx][step])
        if (!isNaN(vel)) {
          // 0.3 ~ 1.0 の範囲にする
          alpha = 0.3 + (vel * 0.7)
        }
      }

      // ハイライト時の色変更 (バー自体の色)
      const isHighlighted = props.highlightIndices.some(
        hIdx => step >= hIdx && step < hIdx + props.highlightWindowSize
      )

      ctx.fillStyle = isHighlighted ? 'red' : baseColor
      ctx.globalAlpha = alpha

      // 矩形として描画 (高さ固定のバー)
      const barHeight = Math.max(2, Math.floor(slotHeight - 2))
      // xはステップの開始位置
      // バーの幅は stepWidth から少し隙間(2px)を引いたもの
      const barWidth = Math.max(1, props.stepWidth - 2)

      ctx.fillRect(x + 1, y - barHeight / 2, barWidth, barHeight)

      ctx.globalAlpha = 1.0
    })
  })

  // ハイライト描画 (オーバーレイで目立たせる)
  if (props.highlightIndices.length > 0 && props.highlightWindowSize > 0) {
    ctx.fillStyle = 'rgba(255, 200, 200, 0.25)'
    props.highlightIndices.forEach(idx => {
      const x = idx * props.stepWidth
      const w = props.highlightWindowSize * props.stepWidth
      ctx.fillRect(x, 0, w, canvasHeight)
    })
  }
}

watch(
  () => [
    props.streamValues,
    props.streamVelocities,
    props.highlightIndices,
    props.stepWidth,
    props.minValue,
    props.maxValue,
    props.valueResolution
  ],
  () => { nextTick(draw) },
  { deep: true }
)

onMounted(() => {
  // マウント直後は親のサイズが決まっていないことがあるため少し待つ
  setTimeout(draw, 100)
})

defineExpose({ scrollWrapper, redraw: draw })
</script>

<style scoped>
.roll-container {
  display: flex;
  border: 1px solid #ccc;
  background: white;
  position: relative;
  height: 100%; /* 親に合わせる */
}
.y-axis {
  width: 50px;
  flex-shrink: 0;
  border-right: 1px solid #ccc;
  position: relative;
  font-size: 10px;
  background: #f0f0f0;
  color: #666;
}
.axis-max { position: absolute; top: 4px; right: 4px; }
.axis-min { position: absolute; bottom: 4px; right: 4px; }
.scroll-wrapper {
  flex-grow: 1;
  overflow-x: auto;
  overflow-y: auto;
}
</style>
