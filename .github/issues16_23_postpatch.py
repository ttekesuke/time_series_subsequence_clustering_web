from pathlib import Path

path = Path('src/voice/voice_token_generation.jl')
text = path.read_text()
old = 'using ..PolyphonicClusterManager\nimport ..TimeSeriesController as TimeSeriesScoring\n'
if old not in text:
    raise SystemExit('expected temporary TimeSeriesScoring import not found')
text = text.replace(old, 'using ..PolyphonicClusterManager\n', 1)

marker = 'function _candidate_complexity_scores(\n'
helper = '''# TimeSeriesController is included after this module. Resolve the canonical
# generation-scoring module lazily at call time to preserve include order while
# keeping one scoring implementation for ordinary dimensions and voice tokens.
function _time_series_scoring_module()
  parent = parentmodule(@__MODULE__)
  isdefined(parent, :TimeSeriesController) || error("TimeSeriesController scoring module is not loaded.")
  return getfield(parent, :TimeSeriesController)
end

'''
if text.count(marker) != 1:
    raise SystemExit('voice candidate scoring marker missing/duplicated')
text = text.replace(marker, helper + marker, 1)
text = text.replace(
    '  distribution = PolyphonicClusterManager.build_predictive_distribution(manager)\n  calibrator = TimeSeriesScoring.build_extended_metric_calibrator(manager)',
    '  scoring = _time_series_scoring_module()\n  distribution = PolyphonicClusterManager.build_predictive_distribution(manager)\n  calibrator = scoring.build_extended_metric_calibrator(manager)',
    1,
)
text = text.replace(
    '  return TimeSeriesScoring.combine_predictive_structural_scores(',
    '  return scoring.combine_predictive_structural_scores(',
    1,
)
if 'TimeSeriesScoring' in text:
    raise SystemExit('temporary TimeSeriesScoring references remain')
path.write_text(text)
print('postpatch applied')

# The finite-fallback patch is kept separate so it can assert the exact
# common-score implementation. Execute it after the base controller patch and
# after the generated regression file exists.
exec(Path('.github/issues16_23_runtime_fix.py').read_text(), {'__name__': '__main__'})
