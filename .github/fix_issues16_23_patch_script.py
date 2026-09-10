from pathlib import Path

path = Path('.github/issues16_23_patch.py')
text = path.read_text()
start_marker = '# #16 create closure binding before resolver definitions.\n'
end_marker = '# #18 always maintain a volume/presence manager, even when volume is fixed.\n'
start = text.index(start_marker)
end = text.index(end_marker, start)
replacement = r'''# #16 create an immutable initial-context snapshot for both AREA and other fixed dimensions.
needle = '  function _fixed_area_band_low_for_stream'
if needle not in gp:
    raise SystemExit('fixed area resolver marker missing')
gp = gp.replace(needle, '  initial_last_step_snapshot = Any[]\n\n' + needle, 1)

old_area = ''' + "'''" + r'''    if get(dim_fixed_source, "area", "manual_input") == "initial_context_last_step"
      last_step = isempty(results) ? Vector{Vector{Any}}() : results[end]''' + "'''" + r'''
new_area = ''' + "'''" + r'''    if get(dim_fixed_source, "area", "manual_input") == "initial_context_last_step"
      last_step = initial_last_step_snapshot''' + "'''" + r'''
gp = replace_once(gp, old_area, new_area, 'fixed AREA snapshot resolver')

generic_old = '    last_step = isempty(results) ? Vector{Vector{Any}}() : results[end]'
generic_new = '    last_step = initial_last_step_snapshot'
gp = replace_once(gp, generic_old, generic_new, 'fixed dimension snapshot resolver')

# Snapshot after initial notes/CR/DEN have been normalized/inferred.
marker = '  merge_threshold_ratio = _parse_float(get(gp, "merge_threshold_ratio", Config.DEFAULT_POLYPHONIC_MERGE_THRESHOLD_RATIO))'
gp = replace_once(
    gp,
    marker,
    '  initial_last_step_snapshot = isempty(results) ? Any[] : deepcopy(results[end])\n\n' + marker,
    'initial last-step snapshot assignment',
)

'''
text = text[:start] + replacement + text[end:]
path.write_text(text)
print('corrected #16 patch section')
