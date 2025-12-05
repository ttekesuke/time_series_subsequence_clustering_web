import { ref, onMounted, onUnmounted } from 'vue'

export const useScrollSync = (refs: any[]) => {
  const isSyncing = ref(false)

  const syncScroll = (e: Event) => {
    if (isSyncing.value) return
    isSyncing.value = true

    const target = e.target as HTMLElement
    const scrollLeft = target.scrollLeft

    refs.forEach(r => {
      const el = r.value
      // scrollWrapperというref名でdivを持っているか、自身がHTMLElement想定
      const scrollEl = el?.scrollWrapper || el
      if (scrollEl && scrollEl !== target) {
        scrollEl.scrollLeft = scrollLeft
      }
    })

    // イベントループによる無限ループ防止
    requestAnimationFrame(() => {
      isSyncing.value = false
    })
  }

  return {
    syncScroll
  }
}
