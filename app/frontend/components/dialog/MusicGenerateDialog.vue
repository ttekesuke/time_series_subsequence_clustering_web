<template>
  <v-dialog height="98%" width="98%" v-model="open" scrollable>
    <v-card>
      <v-card-title class="text-h5 grey lighten-2 d-flex align-center justify-space-between py-2">
        <span>Polyphonic Stream Generation Parameters</span>
        <div class="d-flex align-center">
          <div class="mr-4 text-caption" v-if="progress.status === 'progress' || progress.status === 'rendering'">
            <span v-if="progress.status === 'progress'">Generating: {{progress.percent}}%</span>
            <span v-if="progress.status === 'rendering'">Rendering Audio...</span>
          </div>
          <v-btn
            color="secondary"
            class="mr-2 open-param-gen-btn"
            :disabled="!focusedCell.type"
            @mousedown="setSuppressBlur"
            @click="openParamGenDialog"
          >
            GENERATE PARAMETERS
          </v-btn>
          <v-btn color="success" class="mr-2" :loading="music.loading" @click="handleGeneratePolyphonic">GENERATE & RENDER</v-btn>
          <v-btn icon @click="open = false"><v-icon>mdi-close</v-icon></v-btn>
        </div>
      </v-card-title>

      <v-card-text class="pa-4" style="height: 80vh;">
        <!-- initial/context and generation parameter UI copied from Main.vue -->
        <v-card variant="outlined" class="mb-4 grid-card">
          <v-toolbar density="compact" color="grey-lighten-4" class="px-2">
            <v-toolbar-title class="text-subtitle-1 font-weight-bold">1. Initial Context (Past Context)</v-toolbar-title>
            <v-spacer></v-spacer>
            <div class="d-flex align-center mr-4" style="font-size: 0.9rem;">
              <span class="mr-2">Streams:</span>
              <input type="number" v-model.number="contextStreamCount" min="1" max="16" class="step-input mr-1" @change="updateContextStreams">
            </div>
            <div class="d-flex align-center mr-2" style="font-size: 0.9rem;">
              <span class="mr-2">Steps:</span>
              <input type="number" v-model.number="contextStepCount" min="1" max="100" class="step-input mr-1" @change="updateContextSteps">
            </div>
          </v-toolbar>

          <div class="grid-container">
            <table class="param-grid">
              <thead>
                <tr>
                  <th class="sticky-col head-col" style="width: 100px;">Stream</th>
                  <th class="sticky-col sub-col" style="width: 100px!important;">Param</th>
                  <th v-for="i in contextStepCount" :key="`ctx-h-${i}`" class="data-col">{{ i }}</th>
                </tr>
              </thead>
              <tbody>
                <template v-for="s in contextStreamCount" :key="`s-${s}`">
                  <tr class="dim-start-row">
                    <td class="sticky-col head-col row-label" rowspan="6">Stream {{ s }}</td>
                    <td class="sticky-col sub-col label-dim">OCTAVE</td>
                    <td v-for="(step, i) in polyParams.initial_context" :key="`ctx-${s}-oct-${i}`">
                      <input type="number" v-if="step[s-1]" v-model.number="step[s-1][0]" class="grid-input" min="0" max="10" @paste="onContextPaste($event, s-1, 0, i)" @focus="onContextFocus(s-1, 0, i, { min: 0, max: 10, isInt: true })" @blur="onContextBlur">
                    </td>
                  </tr>
                  <tr v-for="(dim, dIdx) in dimensions.slice(1)" :key="`dim-${dim.key}-${s}`">
                    <td class="sticky-col sub-col label-dim">{{ dim.label }}</td>
                    <td v-for="(step, i) in polyParams.initial_context" :key="`ctx-${s}-${dim.key}-${i}`">
                      <input type="number" v-if="step[s-1]" v-model.number="step[s-1][dIdx + 1]" class="grid-input" :step="dim.key === 'note' ? 1 : 0.1" @paste="onContextPaste($event, s-1, dIdx + 1, i)" @focus="onContextFocus(s-1, dIdx + 1, i, { min: dim.key === 'note' ? 0 : 0, max: dim.key === 'note' ? 11 : 1, isInt: dim.key === 'note' })" @blur="onContextBlur">
                    </td>
                  </tr>
                </template>
              </tbody>
            </table>
          </div>
        </v-card>

        <v-card variant="outlined" class="fill-height grid-card">
          <v-toolbar density="compact" color="grey-lighten-4" class="px-2">
            <v-toolbar-title class="text-subtitle-1 font-weight-bold">2. Generation Parameters (Future Targets)</v-toolbar-title>
            <v-spacer></v-spacer>
            <div class="d-flex align-center mr-2" style="font-size: 0.9rem;">
              <span class="mr-2">Gen Steps:</span>
              <input type="number" v-model.number="newStepCount" min="1" max="100" class="step-input mr-1" @change="updateStepCount">
            </div>
          </v-toolbar>

          <div class="grid-container">
            <table class="param-grid">
              <thead>
                <tr>
                  <th class="sticky-col head-col" style="width: 100px;"></th>
                  <th class="sticky-col sub-col" style="width: 60px;">Param</th>
                  <th v-for="(count, i) in polyParams.stream_counts" :key="i" class="data-col">{{ i + 1 }}</th>
                </tr>
              </thead>
              <tbody>
                <tr class="dim-start-row">
                  <td class="sticky-col head-col row-label" rowspan="1">STREAM</td>
                  <td class="sticky-col sub-col label-count">Count</td>
                  <td v-for="(val, i) in polyParams.stream_counts" :key="`count-${i}`" class="data-col">
                    <input type="number" v-model.number="polyParams.stream_counts[i]" min="1" class="grid-input" @paste="onGenParamPaste($event, polyParams.stream_counts, i, true)" @focus="onGridFocus(polyParams.stream_counts, i, { min: 1, max: 16, isInt: true })" @blur="onGridBlur">
                  </td>
                </tr>

                <template v-for="dim in dimensions" :key="dim.key">
                  <tr class="dim-start-row">
                    <td class="sticky-col head-col row-label" rowspan="4">{{ dim.label }}</td>
                    <td class="sticky-col sub-col label-global">Global</td>
                    <td v-for="(val, i) in polyParams.stream_counts" :key="`g-${dim.key}-${i}`" class="data-col">
                      <input type="number" v-model.number="polyParams[`${dim.key}_global`][i]" step="0.01" min="0" max="1" class="grid-input" @paste="onGenParamPaste($event, polyParams[`${dim.key}_global`], i)" @focus="onGridFocus(polyParams[`${dim.key}_global`], i, { min: 0, max: 1 })" @blur="onGridBlur">
                    </td>
                  </tr>
                  <tr>
                    <td class="sticky-col sub-col label-stream">Ratio</td>
                    <td v-for="(val, i) in polyParams.stream_counts" :key="`r-${dim.key}-${i}`" class="data-col">
                      <input type="number" v-model.number="polyParams[`${dim.key}_ratio`][i]" step="0.01" min="0" max="1" class="grid-input" @paste="onGenParamPaste($event, polyParams[`${dim.key}_ratio`], i)" @focus="onGridFocus(polyParams[`${dim.key}_ratio`], i, { min: 0, max: 1 })" @blur="onGridBlur">
                    </td>
                  </tr>
                  <tr>
                    <td class="sticky-col sub-col label-stream">Tight</td>
                    <td v-for="(val, i) in polyParams.stream_counts" :key="`t-${dim.key}-${i}`" class="data-col">
                      <input type="number" v-model.number="polyParams[`${dim.key}_tightness`][i]" step="0.01" min="0" max="1" class="grid-input" @paste="onGenParamPaste($event, polyParams[`${dim.key}_tightness`], i)" @focus="onGridFocus(polyParams[`${dim.key}_tightness`], i, { min: 0, max: 1 })" @blur="onGridBlur">
                    </td>
                  </tr>
                  <tr>
                    <td class="sticky-col sub-col label-conc">Conc</td>
                    <td v-for="(val, i) in polyParams.stream_counts" :key="`c-${dim.key}-${i}`" class="data-col">
                      <input type="number" v-model.number="polyParams[`${dim.key}_conc`][i]" step="0.01" min="-1" max="1" class="grid-input" @paste="onGenParamPaste($event, polyParams[`${dim.key}_conc`], i)" @focus="onGridFocus(polyParams[`${dim.key}_conc`], i, { min: -1, max: 1 })" @blur="onGridBlur">
                    </td>
                  </tr>
                </template>
              </tbody>
            </table>
          </div>
        </v-card>
      </v-card-text>
    </v-card>
  </v-dialog>

  <!-- Param Gen Dialog -->
  <v-dialog v-model="paramGenDialog" width="500">
    <v-card>
      <v-card-title class="text-h6 bg-grey-lighten-3">Generate Parameters</v-card-title>
      <v-card-text class="pt-4">
        <v-row>
          <v-col cols="12">
            <v-text-field label="Steps to Generate" type="number" v-model.number="paramGen.steps" min="1" hint="Number of cells to fill from cursor" persistent-hint></v-text-field>
          </v-col>
          <v-col cols="12">
            <v-tabs v-model="paramGen.mode" density="compact" color="primary">
              <v-tab value="transition">Transition</v-tab>
              <v-tab value="random">Random</v-tab>
            </v-tabs>
            <v-window v-model="paramGen.mode" class="mt-4">
              <v-window-item value="transition">
                <v-row>
                  <v-col cols="6"><v-text-field label="Start Value" type="number" v-model.number="paramGen.start" step="0.1"></v-text-field></v-col>
                  <v-col cols="6"><v-text-field label="End Value" type="number" v-model.number="paramGen.end" step="0.1"></v-text-field></v-col>
                  <v-col cols="12"><v-select label="Curve Type" :items="easingFunctions" item-title="title" item-value="value" v-model="paramGen.curve"></v-select></v-col>
                </v-row>
              </v-window-item>
              <v-window-item value="random">
                <v-row>
                  <v-col cols="6"><v-text-field label="Min Value" type="number" v-model.number="paramGen.randMin" step="0.1"></v-text-field></v-col>
                  <v-col cols="6"><v-text-field label="Max Value" type="number" v-model.number="paramGen.randMax" step="0.1"></v-text-field></v-col>
                </v-row>
              </v-window-item>
            </v-window>
          </v-col>
        </v-row>
      </v-card-text>
      <v-card-actions>
        <v-spacer></v-spacer>
        <v-btn color="grey" text @click="paramGenDialog = false">Cancel</v-btn>
        <v-btn color="primary" @click="applyGeneratedParams">Generate & Paste</v-btn>
      </v-card-actions>
    </v-card>
  </v-dialog>
</template>

<script setup lang="ts">
import { ref, watch, nextTick } from 'vue'
import axios from 'axios'
import { v4 as uuidv4 } from 'uuid'
import { useJobChannel } from '../../composables/useJobChannel'

const props = defineProps({ modelValue: Boolean, progress: { type: Object, required: false } })
const emit = defineEmits(['update:modelValue', 'generated-polyphonic'])

const open = ref(false)
watch(() => props.modelValue, (v) => open.value = v)
watch(open, (v) => emit('update:modelValue', v))

// music state (local to dialog)
const music = ref({ loading: false, setDataDialog: false, tracks: [], midiData: null })
const progressLocal = props.progress || { percent: 0, status: 'idle' }

// param / grid state (copied minimal logic)
const dimensions = [ { key: 'octave', label: 'OCTAVE' }, { key: 'note', label: 'NOTE' }, { key: 'vol', label: 'VOLUME' }, { key: 'bri', label: 'BRIGHTNESS' }, { key: 'hrd', label: 'HARDNESS' }, { key: 'tex', label: 'TEXTURE' } ]

const steps = 10
const fill = (start, mid, end, len=steps) => { const arr = []; const pivot = Math.floor(len / 2); for (let i = 0; i < len; i++) { if (i < pivot) arr.push(Number((start + (mid - start) * (i / pivot)).toFixed(2))); else arr.push(Number((mid + (end - mid) * ((i - pivot) / (len - pivot - 1))).toFixed(2))); } return arr }
const constant = (val, len=steps) => Array(len).fill(val)

const polyParams = ref({ stream_counts: constant(2), initial_context: [ [[4,0,0.8,0.2,0.2,0.0], [4,7,0.8,0.2,0.2,0.0]], [[4,0,0.8,0.2,0.2,0.0], [4,7,0.8,0.2,0.2,0.0]], [[4,0,0.8,0.2,0.2,0.0], [4,7,0.8,0.2,0.2,0.0]] ], octave_global: fill(0.0,0.1,1.0), octave_ratio: fill(0.0,0.5,1.0), octave_tightness: constant(1.0), octave_conc: fill(0.8,0.5,0.0), note_global: fill(0.2,0.5,0.8), note_ratio: fill(0.0,0.5,1.0), note_tightness: constant(0.5), note_conc: fill(0.8,0.8,0.2), vol_global: constant(0.1), vol_ratio: constant(0.0), vol_tightness: constant(0.0), vol_conc: constant(1.0), bri_global: fill(0.1,0.5,1.0), bri_ratio: fill(0.0,1.0,1.0), bri_tightness: constant(0.5), bri_conc: constant(0.5), hrd_global: fill(0.0,0.2,0.9), hrd_ratio: fill(0.0,0.0,1.0), hrd_tightness: constant(1.0), hrd_conc: constant(0.5), tex_global: fill(0.0,0.0,1.0), tex_ratio: fill(0.0,0.0,1.0), tex_tightness: constant(1.0), tex_conc: constant(0.0) })

const newStepCount = ref(steps)
const contextStepCount = ref(3)
const contextStreamCount = ref(2)

const paramGenDialog = ref(false)
const focusedCell = ref<any>({ type: null, targetArray: null, index: null, constraints: null })
const paramGenTarget = ref<any>(null)
const _suppressBlurClear = ref(false)
const setSuppressBlur = () => { _suppressBlurClear.value = true; setTimeout(() => { _suppressBlurClear.value = false }, 300); };
const paramGen = ref({ steps: 10, mode: 'transition', start: 0, end: 1, curve: 'linear', randMin: 0, randMax: 1 })
const easingFunctions = [ { title: 'Linear', value: 'linear' }, { title: 'Ease In (Quad)', value: 'easeInQuad' }, { title: 'Ease Out (Quad)', value: 'easeOutQuad' }, { title: 'Ease In Out (Quad)', value: 'easeInOutQuad' } ]

// helpers
const updateContextSteps = () => { const targetLen = contextStepCount.value; const current = polyParams.value.initial_context; while (current.length < targetLen) { const lastStep = current[current.length - 1]; current.push(JSON.parse(JSON.stringify(lastStep))); } if (current.length > targetLen) current.splice(targetLen); };
const updateContextStreams = () => { const targetCount = contextStreamCount.value; polyParams.value.initial_context.forEach(step => { while (step.length < targetCount) { step.push([4,0,0.8,0.2,0.2,0.0]); } if (step.length > targetCount) step.splice(targetCount); }); };
const updateStepCount = () => { const targetLen = newStepCount.value; updateArrayLength(polyParams.value.stream_counts, targetLen, 2); dimensions.forEach(dim => { updateArrayLength(polyParams.value[`${dim.key}_global`], targetLen, 0.0); updateArrayLength(polyParams.value[`${dim.key}_ratio`], targetLen, 0.0); updateArrayLength(polyParams.value[`${dim.key}_tightness`], targetLen, 1.0); updateArrayLength(polyParams.value[`${dim.key}_conc`], targetLen, 0.0); }); };
const updateArrayLength = (arr, targetLen, defaultVal) => { while (arr.length < targetLen) arr.push(arr.length > 0 ? arr[arr.length - 1] : defaultVal); if (arr.length > targetLen) arr.splice(targetLen); };

// paste handlers
const onGenParamPaste = (e, targetArr, startIndex, isInt = false) => { e.preventDefault(); const text = e.clipboardData.getData('text'); if (!text) return; const values = text.split(/\s+/).filter(v => v !== '').map(Number); if (values.some(isNaN)) return; const requiredLen = startIndex + values.length; if (requiredLen > polyParams.value.stream_counts.length) { newStepCount.value = requiredLen; updateStepCount(); } values.forEach((val, k) => { if (targetArr[startIndex + k] !== undefined) targetArr[startIndex + k] = isInt ? Math.round(val) : val; }); };

const onContextPaste = (e, streamIdx, dimIdx, stepIdx) => { e.preventDefault(); const text = e.clipboardData.getData('text'); if (!text) return; const values = text.split(/\s+/).filter(v => v !== '').map(Number); if (values.some(isNaN)) return; const requiredLen = stepIdx + values.length; if (requiredLen > polyParams.value.initial_context.length) { contextStepCount.value = requiredLen; updateContextSteps(); } values.forEach((val, k) => { const targetStep = polyParams.value.initial_context[stepIdx + k]; if (targetStep && targetStep[streamIdx]) { const isInt = (dimIdx === 0 || dimIdx === 1); targetStep[streamIdx][dimIdx] = isInt ? Math.round(val) : val; } }); };

const onGridFocus = (targetArr, idx, constraints) => { const findKey = (arr) => { for (const k of Object.keys(polyParams.value)) { try { if (polyParams.value[k] === arr) return k; } catch (e) {} } return null; }; const keyName = findKey(targetArr); focusedCell.value = { type: 'simple', targetArray: targetArr, index: idx, constraints: constraints, keyName: keyName }; };
const onGridBlur = () => { setTimeout(() => { if (_suppressBlurClear.value) return; const active = document.activeElement as HTMLElement | null; if (active && (active.closest('.param-grid') || active.closest('.grid-container') || active.closest('.grid-card'))) return; focusedCell.value = { type: null, targetArray: null, index: null, constraints: null }; }, 0); };
const onContextFocus = (streamIdx, dimIdx, stepIdx, constraints) => { focusedCell.value = { type: 'context', streamIdx, dimIdx, stepIdx, constraints: constraints }; };
const onContextBlur = () => { setTimeout(() => { if (_suppressBlurClear.value) return; const active = document.activeElement as HTMLElement | null; if (active && (active.closest('.param-grid') || active.closest('.grid-container') || active.closest('.grid-card'))) return; focusedCell.value = { type: null, targetArray: null, index: null, constraints: null }; }, 0); };

let _docMouseDownHandler: ((e: MouseEvent) => void) | null = null
const addDocumentClickHandler = () => { if (_docMouseDownHandler) return; _docMouseDownHandler = (e: MouseEvent) => { const t = e.target as HTMLElement | null; if (!t) return; if (t.closest('.param-grid') || t.closest('.grid-container') || t.closest('.grid-card') || t.closest('.open-param-gen-btn')) return; focusedCell.value = { type: null, targetArray: null, index: null, constraints: null }; }; document.addEventListener('mousedown', _docMouseDownHandler); };
const removeDocumentClickHandler = () => { if (!_docMouseDownHandler) return; document.removeEventListener('mousedown', _docMouseDownHandler); _docMouseDownHandler = null; };

watch(() => open.value, (v) => { if (v) addDocumentClickHandler(); else removeDocumentClickHandler() })

// param-gen dialog open/apply
const openParamGenDialog = () => {
  const { type, targetArray, index, stepIdx, constraints } = focusedCell.value || {}
  if (!type) return
  let currentVal = 0
  if (type === 'simple') {
    currentVal = targetArray && targetArray[index] !== undefined ? targetArray[index] : 0
    paramGen.value.steps = Math.max(1, (targetArray ? targetArray.length : 1) - index)
  } else if (type === 'context') {
    const ctx = polyParams.value.initial_context
    if (ctx[stepIdx] && ctx[stepIdx][focusedCell.value.streamIdx]) currentVal = ctx[stepIdx][focusedCell.value.streamIdx][focusedCell.value.dimIdx]
    paramGen.value.steps = Math.max(1, ctx.length - stepIdx)
  }
  paramGenTarget.value = { type: focusedCell.value.type, keyName: focusedCell.value.keyName || null, index: focusedCell.value.index, streamIdx: focusedCell.value.streamIdx, dimIdx: focusedCell.value.dimIdx, stepIdx: focusedCell.value.stepIdx, constraints: focusedCell.value.constraints || null }
  paramGen.value.start = currentVal
  paramGen.value.end = (focusedCell.value && focusedCell.value.constraints) ? focusedCell.value.constraints.max : 1
  paramGen.value.randMin = (focusedCell.value && focusedCell.value.constraints) ? focusedCell.value.constraints.min : 0
  paramGen.value.randMax = (focusedCell.value && focusedCell.value.constraints) ? focusedCell.value.constraints.max : 1
  paramGenDialog.value = true;
};

const applyGeneratedParams = () => {
  const live = focusedCell.value || {}
  const snap = paramGenTarget.value || {}
  const use = (live && live.type) ? live : snap
  const type = use.type
  if (!type) return
  const { steps, mode, start, end, curve, randMin, randMax } = paramGen.value
  const index = use.index
  const streamIdx = use.streamIdx
  const dimIdx = use.dimIdx
  const stepIdx = use.stepIdx
  const constraints = use.constraints || {}
  const safeConstraints = { min: Number.NEGATIVE_INFINITY, max: Number.POSITIVE_INFINITY, isInt: false, ...(constraints || {}) }
  let targetArray = (live && live.targetArray) ? live.targetArray : null
  if (!targetArray && snap && snap.keyName) targetArray = polyParams.value[snap.keyName] || null
  if (type === 'simple') {
    const requiredLen = (index || 0) + steps
    if (requiredLen > polyParams.value.stream_counts.length) { newStepCount.value = requiredLen; updateStepCount() }
  } else if (type === 'context') {
    const requiredLen = (stepIdx || 0) + steps
    if (requiredLen > polyParams.value.initial_context.length) { contextStepCount.value = requiredLen; updateContextSteps() }
  }
  for (let i = 0; i < steps; i++) {
    let val = 0
    if (mode === 'transition') {
      const t = steps > 1 ? i / (steps - 1) : 1
      let easedT = t
      if (curve === 'easeInQuad') easedT = t * t
      if (curve === 'easeOutQuad') easedT = t * (2 - t)
      if (curve === 'easeInOutQuad') easedT = t < 0.5 ? 2 * t * t : -1 + (4 - 2 * t) * t
      val = start + (end - start) * easedT
    } else {
      val = randMin + Math.random() * (randMax - randMin)
    }
    if (safeConstraints.isInt) val = Math.round(val); else val = Number(val.toFixed(2))
    if (val < safeConstraints.min) val = safeConstraints.min
    if (val > safeConstraints.max) val = safeConstraints.max
    if (type === 'simple') { if (targetArray && typeof index === 'number' && targetArray[index + i] !== undefined) targetArray[index + i] = val }
    else if (type === 'context') { const targetStep = polyParams.value.initial_context[(stepIdx || 0) + i]; if (targetStep && typeof streamIdx === 'number') targetStep[streamIdx][dimIdx] = val }
  }
  paramGenTarget.value = null;
  if (type === 'context') polyParams.value.initial_context_json = JSON.stringify(polyParams.value.initial_context, null, 2)
  paramGenDialog.value = false;
};


const handleGeneratePolyphonic = async () => {
  try {
  const parseArr = (str) => Array.isArray(str) ? str : String(str).split(',').map(Number)
  const payload = {
    generate_polyphonic: {
      job_id: uuidv4(),
      stream_counts: parseArr(polyParams.value.stream_counts),
      initial_context: polyParams.value.initial_context

    }
  }
  dimensions.forEach(dim => { payload[`${dim.key}_global`] = parseArr(polyParams.value[`${dim.key}_global`]); payload[`${dim.key}_ratio`] = parseArr(polyParams.value[`${dim.key}_ratio`]); payload[`${dim.key}_tightness`] = parseArr(polyParams.value[`${dim.key}_tightness`]); payload[`${dim.key}_conc`] = parseArr(polyParams.value[`${dim.key}_conc`]) })

    const resp = await axios.post('/api/web/time_series/generate_polyphonic', payload)
    emit('generated-polyphonic', resp.data)
    open.value = false
  } catch (err) {
    console.error('Generate request failed', err)
  } finally {
  }
}

// expose some refs/methods for parent if needed
import { defineExpose } from 'vue'
defineExpose({ open: open });
</script>

<style scoped>
/* minimal styles reused from Main.vue */
.grid-card { overflow-x: auto; overflow-y: hidden; margin-bottom: 16px; }
.grid-container { display: block; width: 100%; overflow-x: auto; }
.param-grid { border-collapse: separate; border-spacing: 0; table-layout: fixed; font-size: 0.8rem; width: max-content; }
.param-grid th, .param-grid td { border: 1px solid #e0e0e0; padding: 2px; text-align: center; min-width: 3.5rem; width: 3.5rem; box-sizing: border-box; height: 1.5rem; white-space: nowrap; }
.sticky-col { position: sticky; z-index: 2; background-color: white; }
.head-col { left: 0; z-index: 3; width: 100px !important; min-width: 100px !important; font-weight: bold; }
.sub-col { left: 100px; z-index: 3; width: 60px !important; min-width: 60px !important; }
.dim-start-row td { border-top: 3px solid #999 !important; }
.row-label { text-align: left; padding-left: 8px; vertical-align: middle; background-color: white; }
.step-input { width: 60px; border: 1px solid #ccc; padding: 2px 5px; border-radius: 4px; background: white; }
</style>
