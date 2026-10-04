import polyphonicDimensionContract from '../../../config/polyphonic_dimensions.json'

export type ManagedDimKey = keyof typeof polyphonicDimensionContract

export type DimensionPolicyConfig = {
  label: string
  min: number
  max: number
  step: number
  isInt: boolean
  defaultUseFixedValue: boolean
  defaultFixedValue: number
}

export type DimensionFixedValueSource = 'initial_context_last_step' | 'manual_input'

export type DimensionPolicyValue = {
  useFixedValue: boolean
  fixedValue: number
  fixedValueSource: DimensionFixedValueSource
}

export const managedDimKeys = Object.keys(polyphonicDimensionContract) as ManagedDimKey[]

export const managedDimPolicyConfigs = Object.fromEntries(
  managedDimKeys.map((key) => {
    const contract = polyphonicDimensionContract[key]
    return [key, {
      label: contract.label,
      min: contract.min,
      max: contract.max,
      step: contract.step,
      isInt: contract.is_int,
      defaultUseFixedValue: contract.ui_default_use_fixed_value,
      defaultFixedValue: contract.ui_default_fixed_value,
    }]
  }),
) as Record<ManagedDimKey, DimensionPolicyConfig>

export const canonicalizeDimensionFixedValueSource = (
  raw: unknown,
): DimensionFixedValueSource => {
  const key = String(raw ?? '').trim().toLowerCase()
  if (
    key === 'initial_context_last_step' ||
    key === 'initial_context' ||
    key === 'context_last_step' ||
    key === 'last_step' ||
    key === 'last-step'
  ) {
    return 'initial_context_last_step'
  }
  return 'manual_input'
}

export const createDefaultDimensionPolicy = (): Record<ManagedDimKey, DimensionPolicyValue> =>
  Object.fromEntries(
    managedDimKeys.map((key) => {
      const config = managedDimPolicyConfigs[key]
      return [key, {
        useFixedValue: config.defaultUseFixedValue,
        fixedValue: config.defaultFixedValue,
        fixedValueSource: 'manual_input' as const,
      }]
    }),
  ) as Record<ManagedDimKey, DimensionPolicyValue>

export const coerceFiniteNumber = (value: unknown, fallback: number) => {
  const numberValue = Number(value)
  return Number.isFinite(numberValue) ? numberValue : fallback
}

export const coerceBoolean = (value: unknown, fallback: boolean) => {
  if (typeof value === 'boolean') return value
  if (typeof value === 'number') return value !== 0
  if (typeof value === 'string') {
    const normalized = value.trim().toLowerCase()
    if (normalized === 'true' || normalized === '1') return true
    if (normalized === 'false' || normalized === '0') return false
  }
  return fallback
}

export const clampDimensionFixedValue = (key: ManagedDimKey, raw: unknown) => {
  const config = managedDimPolicyConfigs[key]
  let value = coerceFiniteNumber(raw, config.defaultFixedValue)
  if (config.isInt) value = Math.round(value)
  return Math.max(config.min, Math.min(config.max, value))
}

export const canonicalizeManagedDimKey = (raw: unknown): ManagedDimKey | null => {
  const key = String(raw ?? '').trim().toLowerCase()
  return key in managedDimPolicyConfigs ? key as ManagedDimKey : null
}

export const resolveManagedDimKey = (raw: unknown): ManagedDimKey =>
  canonicalizeManagedDimKey(raw) ?? 'area'
