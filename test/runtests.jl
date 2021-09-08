using XUnit: @testset, @testcase


@testset "server-metrics.jl" begin
  include("server-metrics.jl")
end
@testset "statsd-exporter.jl" begin
  include("statsd-exporter.jl")
end
@testset "prometheus-exporter.jl" begin
  include("prometheus-exporter.jl")
end
