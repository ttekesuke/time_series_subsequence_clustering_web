<template>
  <div class="viz-container" ref="containerRef">
    <!-- 上段: Value Roll -->
    <div class="viz-row" style="height: 40%;">
      <ValueRoll
        ref="valueRollRef"
        :streamValues="streamValues"
        :streamVelocities="streamVelocities"
        :minValue="minValue"
        :maxValue="maxValue"
        :stepWidth="computedStepWidth"
        :height="300"
        :highlightIndices="highlightedIndices"
        :highlightWindowSize="highlightedWindowSize"
        @scroll="onScroll"
      />
    </div>

    <!-- 下段: Clusters Roll -->
    <div class="viz-row" style="height: 60%;">
      <ClustersRoll
        ref="clustersRollRef"
        :clustersData="clustersData"
        :stepWidth="computedStepWidth"
        :maxSteps="maxSteps"
        @scroll="onScroll"
        @hover-cluster="onHoverCluster"
      />
    </div>
  </div>
</template>

<script setup lang="ts">
import { ref, computed, onMounted, onUnmounted, nextTick, watch } from 'vue'
import ValueRoll from './ValueRoll.vue'
import ClustersRoll from './ClustersRoll.vue'
import { useScrollSync } from '../../composables/useScrollSync'

const props = defineProps({
  streamValues: {
    type: Array,
    default: () => []
  },
  streamVelocities: [Array, Object],
  clustersData: { type: Array, default: () => [] },
  minValue: Number,
  maxValue: Number
})

const containerRef = ref<HTMLElement | null>(null)
const valueRollRef = ref(null)
const clustersRollRef = ref(null)
const containerWidth = ref(containerRef.value ? containerRef.value.clientWidth : 0)
let resizeObserver: ResizeObserver | null = null
// スクロール同期
const { syncScroll } = useScrollSync([valueRollRef, clustersRollRef])
const onScroll = (e) => syncScroll(e)

// ハイライト状態
const highlightedIndices = ref<number[]>([])
const highlightedWindowSize = ref(0)

const onHoverCluster = (clusterInfo) => {
  if (clusterInfo) {
    highlightedIndices.value = clusterInfo.indices
    highlightedWindowSize.value = clusterInfo.windowSize
  } else {
    highlightedIndices.value = []
    highlightedWindowSize.value = 0
  }
}

// 最大ステップ数の計算
const maxSteps = computed(() => {
  if (!props.streamValues) return 100


  return props.streamValues.length
})

const minValue = computed(() => {
  return props.minValue !== undefined ? props.minValue : Math.min(...props.streamValues)
})
const maxValue = computed(() => {
  return props.maxValue !== undefined ? props.maxValue : Math.max(...props.streamValues)
})
// 画面幅に合わせてステップ幅を計算
const computedStepWidth = computed(() => {

  const widthPerStep = containerWidth.value / maxSteps.value

  // 最小幅(2px)を下回る場合はスクロールさせる
  return Math.max(4, widthPerStep)
})

// リサイズ監視
const updateWidth = () => {
  if (containerRef.value && containerRef.value.clientWidth > 0) {
    containerWidth.value = containerRef.value.clientWidth
  }
}

onMounted(() => {
  // nextTickでDOM更新を待つ
  nextTick(() => {
    updateWidth()
  })

  if (containerRef.value) {
    resizeObserver = new ResizeObserver((entries) => {
      for (const entry of entries) {
        // 幅が正しく取得できたタイミングで更新
        if (entry.contentRect.width > 0) {
          containerWidth.value = entry.contentRect.width
        }
      }
    })
    resizeObserver.observe(containerRef.value)
  }
})

onUnmounted(() => {
  if (resizeObserver) {
    resizeObserver.disconnect()
  }
})
</script>

<style scoped>
.viz-container {
  display: flex;
  flex-direction: column;
  height: 100%;
  width: 100%;
  background: white;
}
.viz-row {
  width: 100%;
  overflow: hidden;
}
</style>
