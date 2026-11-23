import { nextTick, onBeforeUnmount, onMounted, ref, type Ref } from 'vue'

/**
 * Measure the actual horizontal plotting viewport inside the first roll.
 * Parent containers can have padding, borders, or layout constraints that make
 * their width differ from the child scroll viewport. The measured width is
 * shared by StreamsRoll and ClustersRoll so both use the same step geometry.
 */
export function useRollViewportWidth(container: Ref<HTMLElement | null>) {
  const width = ref(0)
  let resizeObserver: ResizeObserver | null = null
  let mutationObserver: MutationObserver | null = null
  let observedElement: HTMLElement | null = null

  const measure = (element: HTMLElement | null) => {
    const nextWidth = element?.clientWidth ?? 0
    if (nextWidth > 0 && width.value !== nextWidth) width.value = nextWidth
  }

  const syncObservedElement = () => {
    const root = container.value
    const element = root?.querySelector<HTMLElement>('.roll-container > .scroll-wrapper') ?? null

    if (element !== observedElement) {
      resizeObserver?.disconnect()
      resizeObserver = null
      observedElement = element

      if (element) {
        resizeObserver = new ResizeObserver(() => measure(element))
        resizeObserver.observe(element)
      }
    }

    measure(element)
  }

  const scheduleSync = () => {
    void nextTick(syncObservedElement)
  }

  onMounted(() => {
    const root = container.value
    if (root) {
      mutationObserver = new MutationObserver(scheduleSync)
      mutationObserver.observe(root, { childList: true, subtree: true })
    }
    scheduleSync()
  })

  onBeforeUnmount(() => {
    mutationObserver?.disconnect()
    resizeObserver?.disconnect()
    mutationObserver = null
    resizeObserver = null
    observedElement = null
  })

  return width
}
