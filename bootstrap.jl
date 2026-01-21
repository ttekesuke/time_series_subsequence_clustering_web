(pwd() != @__DIR__) && cd(@__DIR__) # allow starting app from bin/ dir

using TimeseriesClusteringAPI
const UserApp = TimeseriesClusteringAPI
TimeseriesClusteringAPI.main()
