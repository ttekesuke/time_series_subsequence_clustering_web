using Test
using Main.TimeseriesClusteringAPI

const VTG = Main.TimeseriesClusteringAPI.VoiceTokenGeneration

@testset "voice token inventory and clustered generation" begin
  inventory_path = normpath(joinpath(@__DIR__, "..", "config", "voice_inventories", "ja_mora_demo.json"))
  inventory = VTG.load_inventory(inventory_path)

  @test inventory.id == "ja_mora_demo"
  @test inventory.dimensions == 6
  @test length(inventory.tokens) == 10
  @test all(length(token.embedding) == inventory.dimensions for token in inventory.tokens)

  token_a = only(filter(token -> token.id == "a", inventory.tokens))
  token_ka = only(filter(token -> token.id == "ka", inventory.tokens))
  @test VTG.embedding_distance(token_a.embedding, token_a.embedding) == 0.0
  @test VTG.embedding_distance(token_a.embedding, token_ka.embedding) > 0.0

  state = VTG.VoiceTokenState(inventory, [1, 2, 3], 0.02, 2)
  first_ids = VTG.select_voice_ids!(state, [1, 2, 3], 1, [1, 2, 3])
  second_ids = VTG.select_voice_ids!(state, [1, 2, 3], 2, [3, 2, 1])
  no_ids = VTG.select_voice_ids!(state, [1, 2, 3], 0, [1, 2, 3])
  @test first_ids == [1]
  @test length(second_ids) == 2
  @test 1 in second_ids
  @test isempty(no_ids)

  selected = VTG.generate_tokens!(
    state,
    [1, 2];
    global_target=0.5,
    stream_targets=Dict(1 => 0.25, 2 => 0.75),
    concordance=0.0,
    transition_weight=0.1,
    recency=0.5,
  )
  @test Set(keys(selected)) == Set([1, 2])
  valid_ids = Set(item.id for item in inventory.tokens)
  @test all(token.id in valid_ids for token in values(selected))
  @test length(state.global_manager.data) == 4
  @test length(state.stream_managers[1].data) == 4

  discordant = VTG.generate_tokens!(
    state,
    [1, 2];
    global_target=0.0,
    stream_targets=Dict(1 => 0.0, 2 => 0.0),
    concordance=-1.0,
  )
  @test discordant[1].text != discordant[2].text

  target_state = VTG.VoiceTokenState(inventory, [1], 0.02, 2)
  candidates = Vector{Float64}[token.embedding for token in inventory.tokens]
  scores = VTG._candidate_complexity_scores(target_state.stream_managers[1], candidates)
  target = 0.37
  expected_index = argmin(abs(score - target) for score in scores)
  closest = VTG.generate_tokens!(
    target_state,
    [1];
    global_target=1.0,
    stream_targets=Dict(1 => target),
    concordance=0.0,
    transition_weight=0.0,
  )
  @test closest[1].id == inventory.tokens[expected_index].id
end
