import fs from 'node:fs'

const contractUrl = new URL('../../config/polyphonic_dimensions.json', import.meta.url)
const contract = JSON.parse(fs.readFileSync(contractUrl, 'utf8'))

const expectedKeys = [
  'area',
  'chord_range',
  'density',
  'vol',
  'brightness',
  'noise',
  'harmonicity',
  'attack',
  'decay_sustain',
  'release',
]

const actualKeys = Object.keys(contract).sort()
const sortedExpected = [...expectedKeys].sort()
if (JSON.stringify(actualKeys) !== JSON.stringify(sortedExpected)) {
  throw new Error(
    `polyphonic dimension keys mismatch: expected=${sortedExpected.join(',')} actual=${actualKeys.join(',')}`,
  )
}

for (const key of expectedKeys) {
  const entry = contract[key]
  if (!entry || typeof entry !== 'object' || Array.isArray(entry)) {
    throw new Error(`${key}: contract entry must be an object`)
  }

  const numericFields = [
    'min',
    'max',
    'step',
    'ui_default_fixed_value',
    'server_default_fixed_value',
  ]
  for (const field of numericFields) {
    if (typeof entry[field] !== 'number' || !Number.isFinite(entry[field])) {
      throw new Error(`${key}.${field}: expected finite number`)
    }
  }

  for (const field of [
    'is_int',
    'ui_default_use_fixed_value',
    'server_default_accept_params',
  ]) {
    if (typeof entry[field] !== 'boolean') {
      throw new Error(`${key}.${field}: expected boolean`)
    }
  }

  if (typeof entry.label !== 'string' || entry.label.trim() === '') {
    throw new Error(`${key}.label: expected non-empty string`)
  }
  if (entry.min > entry.max) {
    throw new Error(`${key}: min must not exceed max`)
  }
  if (!(entry.step > 0)) {
    throw new Error(`${key}: step must be positive`)
  }
  for (const field of ['ui_default_fixed_value', 'server_default_fixed_value']) {
    if (entry[field] < entry.min || entry[field] > entry.max) {
      throw new Error(`${key}.${field}: default must be within [min,max]`)
    }
  }
  if (entry.is_int) {
    for (const field of ['min', 'max', 'step', 'ui_default_fixed_value', 'server_default_fixed_value']) {
      if (!Number.isInteger(entry[field])) {
        throw new Error(`${key}.${field}: integer dimension requires integer value`)
      }
    }
  }
}

console.log(
  `polyphonic dimension contract OK: ${expectedKeys.length} dimensions, ${contractUrl.pathname}`,
)
