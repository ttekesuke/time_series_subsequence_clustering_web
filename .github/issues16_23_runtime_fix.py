from pathlib import Path

path = Path('src/controllers/time_series_controller.jl')
text = path.read_text()
old = '  denominator <= 0.0 && return (copy(unavailable_fallback), false)\n\n  combined = Float64['
new = '''  if denominator <= 0.0
    fallback = Float64[
      isfinite(value) ? clamp(value, 0.0, 1.0) : Config.DEFAULT_TARGET_01
      for value in unavailable_fallback
    ]
    return (fallback, false)
  end

  combined = Float64['''
if text.count(old) != 1:
    raise SystemExit(f'expected one occurrence fallback, found {text.count(old)}')
text = text.replace(old, new, 1)
path.write_text(text)

# Strengthen the regression: the common score must stay finite when prediction
# and interval evidence are unavailable.
test_path = Path('test/issues_16_23_regressions.jl')
test = test_path.read_text()
old_test = '  @test actual_nr ≈ expected_nr atol=1e-12\n  @test any(!isfinite, predictive_nr) || length(unique(round.(predictive_nr; digits=10))) <= 1'
new_test = '  @test actual_nr ≈ expected_nr atol=1e-12\n  @test all(isfinite, actual_nr)\n  @test any(!isfinite, predictive_nr) || length(unique(round.(predictive_nr; digits=10))) <= 1'
if test.count(old_test) != 1:
    raise SystemExit('voice fallback test anchor missing')
test = test.replace(old_test, new_test, 1)
test_path.write_text(test)
print('finite common-score fallback applied')
