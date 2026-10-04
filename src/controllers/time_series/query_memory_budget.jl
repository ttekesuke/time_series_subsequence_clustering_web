function _chunk_series_by_memory_budget(series_stats)::Vector{Any}
  budget_bytes = _query_memory_budget_bytes()
  bytes_per_point = max(32, _parse_int(get(ENV, "QUERY_DB_ESTIMATED_BYTES_PER_POINT", 256)))
  max_points = max(1, Int(floor(budget_bytes / bytes_per_point)))
  max_series_per_chunk = max(1, _parse_int(get(ENV, "QUERY_DB_MAX_SERIES_PER_CHUNK", "50")))

  chunks = Any[]
  current = Any[]
  current_points = 0

  for stat in series_stats
    point_count = max(1, _parse_int(get(stat, "count", 1)))
    if !isempty(current) && (current_points + point_count > max_points || length(current) >= max_series_per_chunk)
      push!(chunks, current)
      current = Any[]
      current_points = 0
    end
    push!(current, stat)
    current_points += point_count
  end

  isempty(current) || push!(chunks, current)
  return chunks
end

function _query_memory_budget_bytes()::Int
  override_mb = get(ENV, "QUERY_DB_MEMORY_BUDGET_MB", "")
  if !isempty(strip(string(override_mb)))
    return max(1, _parse_int(override_mb)) * 1024 * 1024
  end

  available = _available_memory_bytes()
  if available <= 0
    return 256 * 1024 * 1024
  end

  min_budget = 32 * 1024 * 1024
  max_budget = 512 * 1024 * 1024
  return Int(clamp(floor(available * 0.25), min_budget, max_budget))
end

function _available_memory_bytes()::Int
  sys_free = try
    Int(Sys.free_memory())
  catch
    0
  end

  cgroup_free = _cgroup_available_memory_bytes()
  if sys_free > 0 && cgroup_free > 0
    return min(sys_free, cgroup_free)
  elseif cgroup_free > 0
    return cgroup_free
  else
    return sys_free
  end
end

function _cgroup_available_memory_bytes()::Int
  v2_max = _read_memory_limit_file("/sys/fs/cgroup/memory.max")
  v2_current = _read_memory_limit_file("/sys/fs/cgroup/memory.current")
  if v2_max > 0 && v2_current >= 0
    return max(0, v2_max - v2_current)
  end

  v1_max = _read_memory_limit_file("/sys/fs/cgroup/memory/memory.limit_in_bytes")
  v1_current = _read_memory_limit_file("/sys/fs/cgroup/memory/memory.usage_in_bytes")
  if v1_max > 0 && v1_current >= 0
    return max(0, v1_max - v1_current)
  end

  return 0
end

function _read_memory_limit_file(path::AbstractString)::Int
  isfile(path) || return -1
  raw = strip(read(path, String))
  raw == "max" && return 0
  value = tryparse(Int, raw)
  value === nothing && return -1
  value > 9_000_000_000_000_000_000 && return 0
  return value
end
