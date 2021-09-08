using ServerMetrics
using Sockets
using Dates
using ServerMetrics: AbstractMetric, NumericMetric, MetricGroup
using ServerMetrics: register!, unregister!, clear_registry!
using ServerMetrics: get_metric
using ServerMetrics: get_cells
using DataStructures: SortedDict
using Test: @test, @test_throws, @test_logs

get_cell_values(m) = Dict(cell.labels => cell.value[] for cell in get_cells(m))
metric_values(m::NumericMetric) = m.value[]
metric_values(m::MetricGroup) = Dict(k => v.value[] for (k, v) in m.cells)
metric_values(m::AbstractMetric) = metric_values(m.content)
is_dummy(x) = isa(x, ServerMetrics.DummyCell)

@testcase "get_cell! with invalid labels" begin
    cnt = Counter(;action=String, code=Int64)
    @test is_dummy(ServerMetrics.get_cell!(cnt; action="get"))
    @test is_dummy(ServerMetrics.get_cell!(cnt; action="get", code=200, unknown="foo"))
    @test is_dummy(ServerMetrics.get_cell!(cnt; action="get", code=nothing))
end

@testcase "get_cell_if_exists does not create new cells" begin
    cnt = Counter(;day=String)
    @test ServerMetrics.get_cell_if_exists(cnt; day="Monday") == nothing
    @test metric_values(cnt) == Dict()

    @test ServerMetrics.get_cell!(cnt; day="Monday") isa NumericMetric
    @test ServerMetrics.get_cell_if_exists(cnt; day="Monday") isa NumericMetric
    @test metric_values(cnt) ==Dict(Dict(:day => "Monday") => 0.0)
end

@testcase "Invalid access is ignored" begin
    cnt = Counter(;action=String)
    inc!(cnt; action="get")
    inc!(cnt; unknown=nothing) # This is invalid
    inc!(cnt; action="put", mystery=1) # This is invalid
    inc!(cnt) # This is also invalid (missing action label)
    @test metric_values(cnt) == Dict(
        Dict(:action => "get") => 1.0
    )
end

@testcase "get_cell! for singular counter" begin
    cnt = Counter()
    @test is_dummy(ServerMetrics.get_cell!(cnt; label=10))
    @test ServerMetrics.get_cell_if_exists(cnt; label=10) == nothing
    @test ServerMetrics.get_cell_if_exists(cnt) == cnt.content
    @test ServerMetrics.get_cell!(cnt) == cnt.content
end

@testcase "get_cell with Counter" begin
    cnt = Counter(;action=String, code=Int64)
    @test metric_values(cnt) == Dict()

    @test ServerMetrics.get_cell!(cnt; action="get", code=200) isa NumericMetric
    @test metric_values(cnt) == Dict(
        Dict(:action => "get", :code => 200) => 0.0,
    )

    ServerMetrics.get_cell!(cnt; action="get", code=500)
    ServerMetrics.get_cell!(cnt; action="put", code=200)
    @test metric_values(cnt) == Dict(
        Dict(:action => "get", :code => 200) => 0.0,
        Dict(:action => "get", :code => 500) => 0.0,
        Dict(:action => "put", :code => 200) => 0.0,
    )
end

@testcase "Counter with labels " begin
    c = Counter(;action=String, response_code=Int64)
    inc!(c; action="get", response_code=404)
    inc!(c; action="put", response_code=200)
    inc!(c, 2.0; action="get", response_code=404)

    @test metric_values(c) == Dict(
        Dict(:action => "get", :response_code => 404) => 3.0,
        Dict(:action => "put", :response_code => 200) => 1.0,
    )
end

@testcase "Gauge with labels" begin
    g = Gauge(;resource=String)
    set!(g, 20.0; resource="disk")
    inc!(g; resource="disk")
    dec!(g, 5.0; resource="water_level")
    inc!(g, 2.0; resource="water_level")
    @test metric_values(g) == Dict(
        Dict(:resource => "disk") => 21.0,
        Dict(:resource => "water_level") => -3.0,
    )
end

@testcase "Counter with no labels has one cell" begin
    c = Counter()
    @test length(get_cells(c)) == 1
    inc!(c, 2.5)
    @test metric_values(c) == 2.5
end

@testcase "Simple counter manipulations" begin
    c = ServerMetrics.Counter()
    @test metric_values(c) == 0.0
    inc!(c)
    @test metric_values(c) == 1.0
    inc!(c, 2)
    @test metric_values(c) == 3.0

    # Incrementing by negative value is logged and ignored
    inc!(c, -1.0)
    @test metric_values(c) == 3.0
end

@testcase "Gauge constructors" begin
    g1 = ServerMetrics.Gauge()
    @test metric_values(g1) == 0.0

    g2 = ServerMetrics.Gauge(10.0)
    @test metric_values(g2) == 10.0
end

@testcase "Simple gauge manipulations" begin
    g = ServerMetrics.Gauge()
    @test metric_values(g) == 0.0
    inc!(g)
    @test metric_values(g) == 1.0
    inc!(g, 2)
    @test metric_values(g) == 3.0

    inc!(g, -1.0)
    @test metric_values(g) == 3.0

    dec!(g, -1.0)
    @test metric_values(g) == 3.0
    # TODO(janrous): Perhaps we might consider chg!(g, v) which will
    # inc! or dec! based on the sign?
end

@testcase "Registry enforces unique names" begin
    r = ServerMetrics.MetricRegistry()
    c1 = ServerMetrics.Counter()
    register!(r, c1, "first_name")
    c2 = ServerMetrics.Counter()
    register!(r, c2, "second_name")
    @test ServerMetrics.name(c1) == "first_name"
    @test ServerMetrics.name(c2) == "second_name"
    c3 = ServerMetrics.Counter()
    @test_throws KeyError register!(r, c3, "first_name")
    @test ServerMetrics.name(c3) == nothing
end

@testcase "Once registered, name remains fixed" begin
    r = ServerMetrics.MetricRegistry()
    c = ServerMetrics.Counter()
    @test ServerMetrics.name(c) === nothing
    register!(r, c, "my_name")
    @test ServerMetrics.name(c) == "my_name"
    unregister!(r, "my_name")
    @test ServerMetrics.name(c) == "my_name"
end

@testcase "overwriting existing metrics" begin
    r = ServerMetrics.MetricRegistry()
    c1 = ServerMetrics.Counter()
    c2 = ServerMetrics.Counter()
    register!(r, c1, "first_name")
    @test_throws KeyError register!(r, c2, "first_name")
    @test get_metric(r, "first_name") == c1
    @test_logs (:warn,) register!(r, c2, "first_name"; overwrite=true)
    @test get_metric(r, "first_name") == c2
end

# Returns sorted Array of metric names registered within given registry.
list_metrics(r::ServerMetrics.MetricRegistry) = sort(collect(keys(r.metrics)))


# Uniqueness of metric name is enforced within a single registry. Two registries
# can have metric with the same name.
@testcase "Metrics unique within registry" begin
    r1 = ServerMetrics.MetricRegistry()
    r2 = ServerMetrics.MetricRegistry()
    g1 = ServerMetrics.Gauge(1.0)
    g2 = ServerMetrics.Gauge(3.0)
    register!(r1, g1, "unique")
    register!(r2, g2, "unique")
    @test list_metrics(r1) == ["unique"]
    @test list_metrics(r2) == ["unique"]
    @test metric_values(get_metric(r1, "unique")) == 1.0
    @test metric_values(get_metric(r2, "unique")) == 3.0
end

# Single metric can only be registered once.
@testcase "Name constraints on metrics are enforced" begin
    r1 = ServerMetrics.MetricRegistry()
    r2 = ServerMetrics.MetricRegistry()
    c = ServerMetrics.Counter()
    register!(r1, c, "my_counter")

    # Registering under the same name twice is okay
    @test_logs register!(r2, c, "my_counter")

    # Registering under different name is not okay
    @test_throws AssertionError register!(r2, c, "my_counter_2")
end

@testcase "Multiple registration with same name okay" begin
    r1 = ServerMetrics.MetricRegistry()
    r2 = ServerMetrics.MetricRegistry()
    c = ServerMetrics.Counter()
    register!(r1, c, "my_counter")
    @test_logs register!(r2, c, "my_counter")
end


# Metric could be registered sequentially in two registries if it's unregistered from one.
@testcase "Sequential multiple registration" begin
    r1 = ServerMetrics.MetricRegistry()
    r2 = ServerMetrics.MetricRegistry()
    c = ServerMetrics.Counter()
    register!(r1, c, "my_counter")
    unregister!(r1, "my_counter")
    register!(r2, c, "my_counter")
    @test list_metrics(r1) == []
    @test list_metrics(r2) == ["my_counter"]
end

@testcase "Metric name length enforced" begin
    @test_throws ArgumentError register!(
        MetricRegistry(),
        ServerMetrics.Counter(),
        "c"^201
    )
end

@testcase "Metric name validation" begin
    r = MetricRegistry()
    c = ServerMetrics.Counter()
    @test_throws ArgumentError register!(r, c, "hyphens-not-permitted")
    @test_throws ArgumentError register!(r, c, ".tralala")
    @test_throws ArgumentError register!(r, c, "2tralala")
    @test_throws ArgumentError register!(r, c, "tra\\lala")
    @test_throws ArgumentError register!(r, c, "t,r()a22ala")
    @test_throws ArgumentError register!(r, c, "prometheus.dislikes.this")
end

# Turn Dict keys into Return sorted array of keys from Dict
key_set(d::SortedDict) = Set([first(kv) for kv in d])

Base.@kwdef struct ThreeMetrics <: AbstractMetricCollection
    a = Counter()
    b = Counter()
    c = Gauge(5.0)
end

Base.@kwdef struct CounterAndTwoGauges <: AbstractMetricCollection
    c = Counter()
    g1 = Gauge()
    g2 = Gauge()
end

Base.@kwdef struct CounterAndGauge <: AbstractMetricCollection
    c = Counter()
    g = Gauge()
end

@testcase "Int64 counter manipulations" begin
    c = Counter()
    inc!(c, 2)
    @test metric_values(c) == 2.0
end

@testcase "Int64 gauge manipulations" begin
    g = Gauge(0)

    inc!(g, 1)
    @test metric_values(g) == 1.0

    dec!(g, 2)
    @test metric_values(g) == -1.0

    set!(g, 5)
    @test metric_values(g) == 5.0
end

@testcase "Unregister from registry" begin
    r = MetricRegistry()
    @test list_metrics(r) == []
    register!(r, Counter(), "aaa")
    register!(r, Counter(), "bbb")
    @test list_metrics(r) == ["aaa", "bbb"]
    @test_throws KeyError unregister!(r, "nonexistent")
    unregister!(r, "aaa")
    @test list_metrics(r) == ["bbb"]
    unregister!(r, "bbb")
    @test list_metrics(r) == []
end

@testcase "Clear registry" begin
    r = MetricRegistry()
    @test list_metrics(r) == []
    clear_registry!(r)
    @test list_metrics(r) == []
    register!(r, Counter(), "aaa")
    register!(r, Counter(), "bbb")
    @test list_metrics(r) == ["aaa", "bbb"]
    clear_registry!(r)
    @test list_metrics(r) == []
    register!(r, Counter(), "bbb")
    @test list_metrics(r) == ["bbb"]
end

Base.@kwdef struct MixedMetrics <: AbstractMetricCollection
    my_counter = Counter()
    my_gauge = Gauge()

    other_stuff::String = "default_value"
    anything::Any = nothing
end

@testcase "Collection with nonmetric fields" begin
    r = MetricRegistry(MixedMetrics())
    @test list_metrics(r) == ["my_counter", "my_gauge"]
end

Base.@kwdef struct ArbitraryStruct
    my_counter_1 = Counter()
    name::String = "String thingy"
end

@testcase "Collection of any type" begin
    r = MetricRegistry(ArbitraryStruct())
    @test list_metrics(r) == ["my_counter_1"]
end

Base.@kwdef struct FirstGroup <: AbstractMetricCollection
    first_counter = Counter()
    first_gauge = Gauge()
end

Base.@kwdef struct SecondGroup <: AbstractMetricCollection
    second_counter = Counter()
    second_gauge = Gauge()
end

@testcase "Register non-overlapping collections" begin
    first_group = FirstGroup()
    second_group = SecondGroup()
    r = MetricRegistry()

    @test list_metrics(r) == []

    register_collection!(r, first_group)
    @test list_metrics(r) == ["first_counter", "first_gauge"]

    register_collection!(r, second_group)
    @test list_metrics(r) == ["first_counter", "first_gauge", "second_counter", "second_gauge"]
end

@testcase "MAX_CELLS_PER_METRIC triggers" begin
    cnt = Counter(;order=Int64)
    for i in 1:205
        inc!(cnt, i; order=i)
    end
    # only the last 200 cells should be present. Timestmaps may not change fast enough
    # to ensure that LRU will behave in a stable manner.
    @test length(metric_values(cnt)) == 200
end

@testcase "Zero all metrics" begin
    r = MetricRegistry()
    c = register!(r, ServerMetrics.Counter(), "my_counter")
    g = register!(r, ServerMetrics.Gauge(), "my_gauge")
    c_free = ServerMetrics.Counter()

    inc!(c, 2.0)
    set!(g, 5.0)
    inc!(c_free)

    @test metric_values(c) == 2.0
    @test metric_values(g) == 5.0
    @test metric_values(c_free) == 1.0

    ServerMetrics.zero_all_metrics(r)

    @test metric_values(c) == 0.0
    @test metric_values(g) == 0.0
    @test metric_values(c_free) == 1.0
end

@testcase "value_of for simple metrics" begin
    r = MetricRegistry()
    c = register!(r, ServerMetrics.Counter(), "my_counter")
    g = register!(r, ServerMetrics.Gauge(), "my_gauge")
    inc!(c)
    set!(g, 50)
    @test ServerMetrics.value_of(r, "my_counter") == 1.0
    @test ServerMetrics.value_of(r, "my_gauge") == 50.0
    @test ServerMetrics.value_of(r, "unknown") == nothing
end

@testcase "value_of for labelled metrics" begin
    r = MetricRegistry()
    c = register!(r, ServerMetrics.Counter(;response_code=Int64, action=String), "my_counter")
    inc!(c; action="GET", response_code=200)
    inc!(c; action="PUT")  # This inc! is invalid due to bad labels and should be silently ignored.

    # The following doesn't work because all labels are missing.
    @test ServerMetrics.value_of(r, "my_counter") == nothing

    # The following doesn't work because unknown "badlabel" is present.
    @test ServerMetrics.value_of(r, "my_counter"; action="GET", response_code=200, badlabel=1) == nothing

    # The following doesn't work because "response_code" label is missing.
    @test ServerMetrics.value_of(r, "my_counter"; action="PUT") == nothing

    # The following works and refers to the cell created above.
    @test ServerMetrics.value_of(r, "my_counter"; action="GET", response_code=200) == 1.0
end
