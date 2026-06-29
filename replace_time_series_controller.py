import re

with open("src/controllers/time_series_controller.jl", "r") as f:
    content = f.read()

# Replace TimeSeriesClusterManager with PolyphonicClusterManager.Manager in query_db
content = re.sub(
    r"query_seed_manager = TimeSeriesClusterManager\(\n\s*copy\(q_int\),\n\s*merge_threshold,\n\s*min_window,\n\s*true;\n\s*scale_mode = :range_fixed,\n\s*range_min = candidate_min_master,\n\s*range_max = candidate_max_master\n\s*\)",
    "query_seed_manager = PolyphonicClusterManager.Manager(\n    Vector{Float64}[[float(v)] for v in q_int],\n    merge_threshold,\n    min_window,\n    true;\n    scale_mode = :range_fixed,\n    range_min = candidate_min_master,\n    range_max = candidate_max_master\n  )",
    content
)

content = re.sub(
    r"process_data!\(query_seed_manager\)",
    "PolyphonicClusterManager.process_data!(query_seed_manager)",
    content
)

content = re.sub(
    r"add_data_point_permanently!\(manager, _parse_int\(v\)\)",
    "PolyphonicClusterManager.add_data_point_permanently!(manager, Float64[_parse_int(v)])",
    content
)

content = re.sub(
    r"timeline = clusters_to_timeline\(manager\.clusters, min_window\)",
    "timeline = PolyphonicClusterManager.clusters_to_timeline(manager.clusters, min_window)",
    content
)

content = re.sub(
    r"\"clusters\" => clusters_to_dict\(manager\.clusters\)",
    "\"clusters\" => PolyphonicClusterManager.clusters_to_dict(manager.clusters)",
    content
)

# Analyse
content = re.sub(
    r"manager = TimeSeriesClusterManager\(\n\s*copy\(data\),\n\s*merge_threshold_ratio,\n\s*min_window_size,\n\s*calculate_distance_when_added_subsequence_to_cluster;\n\s*scale_mode = :contextual_global_halves,\n\s*contextual_min_width = contextual_min_width\n\s*\)",
    "manager = PolyphonicClusterManager.Manager(\n    Vector{Float64}[[float(v)] for v in data],\n    merge_threshold_ratio,\n    min_window_size,\n    calculate_distance_when_added_subsequence_to_cluster;\n    scale_mode = :contextual_global_halves,\n    contextual_min_width = contextual_min_width\n  )",
    content
)

content = re.sub(
    r"process_data!\(manager\)",
    "PolyphonicClusterManager.process_data!(manager)",
    content
)

content = re.sub(
    r"timeline = clusters_to_timeline\(manager\.clusters, min_window_size\)",
    "timeline = PolyphonicClusterManager.clusters_to_timeline(manager.clusters, min_window_size)",
    content
)


# Generate
content = re.sub(
    r"manager = TimeSeriesClusterManager\(\n\s*copy\(first_elements\),\n\s*merge_threshold_ratio,\n\s*min_window_size,\n\s*calculate_distance_when_added_subsequence_to_cluster;\n\s*scale_mode = :contextual_global_halves,\n\s*range_min = candidate_min_master,\n\s*range_max = candidate_max_master,\n\s*contextual_min_width = contextual_min_width\n\s*\)",
    "manager = PolyphonicClusterManager.Manager(\n    Vector{Float64}[[float(v)] for v in first_elements],\n    merge_threshold_ratio,\n    min_window_size,\n    calculate_distance_when_added_subsequence_to_cluster;\n    scale_mode = :contextual_global_halves,\n    range_min = candidate_min_master,\n    range_max = candidate_max_master,\n    contextual_min_width = contextual_min_width\n  )",
    content
)

content = re.sub(
    r"clusters_each = transform_clusters\(manager\.clusters, min_window_size\)",
    "clusters_each = PolyphonicClusterManager.transform_clusters(manager.clusters, min_window_size)",
    content
)

content = re.sub(
    r"delta_d, delta_q, delta_c = simulate_add_and_calculate\(manager, c_int, \[\]\)",
    "delta_d, delta_q, delta_c = PolyphonicClusterManager.simulate_add_and_calculate(manager, Float64[c_int], Int[])",
    content
)

content = re.sub(
    r"add_data_point_permanently!\(manager, c_int\)",
    "PolyphonicClusterManager.add_data_point_permanently!(manager, Float64[c_int])",
    content
)

content = re.sub(
    r"update_caches_permanently!\(manager, \[\]\)",
    "PolyphonicClusterManager.update_caches_permanently!(manager, Int[])",
    content
)

with open("src/controllers/time_series_controller.jl", "w") as f:
    f.write(content)

