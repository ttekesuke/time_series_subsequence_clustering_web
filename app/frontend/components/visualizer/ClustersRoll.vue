<template>
  <div class="roll-container">
    <div class="scroll-wrapper" ref="scrollWrapper" @scroll="onScroll">
      <canvas ref="canvas" :height="computedHeight"></canvas>
    </div>
  </div>
</template>

<script setup lang="ts">
import { ref, onMounted, watch, nextTick } from 'vue'

type ClusterData = {
  window_size: number;
  cluster_id: string;
  indices: number[];
}

const props = defineProps({
  clustersData: { type: Array as () => ClusterData[], required: true },
  stepWidth: { type: Number, default: 10 },
  rowHeight: { type: Number, default: 12 },
  maxSteps: { type: Number, default: 100 }
})

const emit = defineEmits(['scroll', 'hover-cluster'])

const scrollWrapper = ref<HTMLElement | null>(null)
const canvas = ref<HTMLCanvasElement | null>(null)
const computedHeight = ref(200)
// 現在のスクロール位置を保持 (ラベルの追従用)
const scrollLeft = ref(0)

// 描画用データ
let layoutMap: any[] = []
// グループ境界情報
let groupBoundaries: any[] = []

const calculateLayout = () => {
  if (!props.clustersData) return

  // window_sizeごとにグループ化
  const groups = {} as Record<number, ClusterData[]>
  props.clustersData.forEach(c => {
    if (!groups[c.window_size]) groups[c.window_size] = []
    groups[c.window_size].push(c)
  })

  let currentY = 10
  layoutMap = []
  groupBoundaries = []

  // WindowSizeの小さい順に処理
  Object.keys(groups).sort((a,b) => Number(a) - Number(b)).forEach(wsKey => {
    const ws = Number(wsKey)
    const clusters = groups[ws]

    // グループ開始Y位置
    const startY = currentY

    // 干渉回避ロジック (レーン割り当て)
    const lanes: number[] = []

    clusters.forEach(cluster => {
      cluster.indices.forEach(startIdx => {
        const endIdx = startIdx + ws

        // 配置可能なレーンを探す
        let placedLane = -1
        for (let l = 0; l < lanes.length; l++) {
          if (lanes[l] <= startIdx) {
            placedLane = l
            lanes[l] = endIdx + 0.5
            break
          }
        }
        // 空きがなければ新しいレーン作成
        if (placedLane === -1) {
          placedLane = lanes.length
          lanes.push(endIdx + 0.5)
        }

        layoutMap.push({
          x: startIdx * props.stepWidth,
          y: currentY + (placedLane * props.rowHeight),
          w: ws * props.stepWidth,
          h: props.rowHeight - 6,
          clusterId: cluster.cluster_id,
          indices: cluster.indices,
          windowSize: ws
        })
      })
    })

    const groupHeight = lanes.length * props.rowHeight
    currentY += groupHeight + 10 // マージン

    // グループ情報を保存 (描画時に使用)
    groupBoundaries.push({
      y: currentY - 5, // 境界線のY座標
      labelY: startY,  // ラベルを表示するY座標(グループの上部)
      windowSize: ws
    })
  })

  computedHeight.value = currentY + 20 // 余白
}

const draw = () => {
  if (!canvas.value) return
  const ctx = canvas.value.getContext('2d')
  if (!ctx) return

  // 幅はコンテナ幅より大きくないとスクロールしないので、データ量に合わせる
  const contentWidth = props.maxSteps * props.stepWidth
  // 最低でもラッパーと同じ幅にする
  const wrapperWidth = scrollWrapper.value ? scrollWrapper.value.clientWidth : 1000
  const width = Math.max(wrapperWidth, contentWidth)

  canvas.value.width = width

  ctx.clearRect(0, 0, width, computedHeight.value)

  // 1. バーの描画
  ctx.fillStyle = 'rgba(100, 181, 246, 0.3)' // 薄い青
  ctx.strokeStyle = '#1976D2'

  layoutMap.forEach(item => {
    ctx.fillRect(item.x, item.y, item.w, item.h)
    ctx.strokeRect(item.x, item.y, item.w, item.h)
  })

  // 2. グループ境界線とラベルの描画 (フローティング)
  // 左端の固定位置 = 現在のスクロール位置
  const stickyX = scrollLeft.value

  groupBoundaries.forEach((boundary) => {
    // 横線 (全幅)
    ctx.beginPath()
    ctx.moveTo(0, boundary.y)
    ctx.lineTo(width, boundary.y)
    ctx.strokeStyle = '#ccc'
    ctx.lineWidth = 1
    ctx.stroke()

    // ラベル (背景付きで左端に描画)
    const label = `Window Size: ${boundary.windowSize}`
    const labelY = boundary.labelY + 12

    // ラベル背景 (文字が見やすいように半透明の白)
    ctx.fillStyle = 'rgba(255, 255, 255, 0.9)'
    ctx.fillRect(stickyX, boundary.labelY, 120, 20)

    // ラベル文字
    ctx.fillStyle = '#666'
    ctx.font = 'bold 11px sans-serif'
    ctx.textAlign = 'left'
    ctx.fillText(label, stickyX + 5, labelY)
  })
}

const onScroll = (e: Event) => {
  const target = e.target as HTMLElement
  scrollLeft.value = target.scrollLeft
  emit('scroll', e)
  // スクロール時に再描画してラベル位置を更新(アニメーションフレームで同期)
  requestAnimationFrame(draw)
}

const onMouseMove = (e: MouseEvent) => {
  if (!canvas.value) return
  const rect = canvas.value.getBoundingClientRect()
  const mx = e.clientX - rect.left
  const my = e.clientY - rect.top

  const hit = layoutMap.find(item =>
    mx >= item.x && mx <= item.x + item.w &&
    my >= item.y && my <= item.y + item.h
  )

  if (hit) {
    emit('hover-cluster', { indices: hit.indices, windowSize: hit.windowSize, id: hit.clusterId })
    canvas.value.style.cursor = 'pointer'
  } else {
    emit('hover-cluster', null)
    canvas.value.style.cursor = 'default'
  }
}

watch(() => [props.clustersData, props.stepWidth], () => {
  calculateLayout()
  nextTick(draw)
}, { deep: true })

onMounted(() => {
  if(canvas.value) {
    canvas.value.addEventListener('mousemove', onMouseMove)
    canvas.value.addEventListener('mouseleave', () => emit('hover-cluster', null))
  }
  setTimeout(() => {
      calculateLayout()
      draw()
  }, 100)
})

defineExpose({ scrollWrapper })
</script>

<style scoped>
.roll-container {
  display: flex;
  border: 1px solid #ccc;
  background: white;
  height: 100%;
  position: relative;
}
.scroll-wrapper {
  flex-grow: 1;
  overflow-x: auto;
  overflow-y: auto;
}
</style>
