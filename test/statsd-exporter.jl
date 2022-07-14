using ServerMetrics
using Test: @test, @test_throws
using Dates

# For testing purposes we also have MockStatsdBackend that simply stores the statds
# messages in a Set (unordered) and offers empty! method to clear the buffer.
Base.@kwdef mutable struct MockStatsdBackend <: ServerMetrics.AbstractServiceBackend
    messages::Set{String} = Set{String}()
end
ServerMetrics.send(b::MockStatsdBackend, msg::String) = push!(b.messages, msg)
function clear_messages!(b::MockStatsdBackend)
    b.messages = Set{String}()
end

# Every time we want to trigger statsd updates we want to clear existing
# messages from the MockStatsdBackend and we also want to wait for 1ms to
# ensure that the clock has time to advance.
# We have experienced issues where clock was running too slow and emissions
# and changes to metrics were happening at the same time.
function test_friendly_export_to_statsd(statsd::MockStatsdBackend, exporter::StatsdExporter)
    clear_messages!(statsd)
    # Ensure that the time of an emission is distinct from any other times
    # when metrics can be set by padding this call with small delays both
    # before and after.
    sleep(0.01)
    ServerMetrics.send_metric_updates(exporter)
    sleep(0.01)
end

@testcase "Counter changes" begin
    mock_statsd = MockStatsdBackend()
    r = MetricRegistry()
    c = register!(r, Counter(), "counter")
    exporter = StatsdExporter(metric_registries=Set([r]), statsd_backend=mock_statsd)

    test_friendly_export_to_statsd(mock_statsd, exporter)
    @test mock_statsd.messages == Set(["counter:0.0|c"])

    inc!(c, 1.0)
    test_friendly_export_to_statsd(mock_statsd, exporter)
    @test mock_statsd.messages == Set(["counter:1.0|c"])
    @test c.content.value[] == 1.0

    test_friendly_export_to_statsd(mock_statsd, exporter)
    @test mock_statsd.messages == Set()
    @test c.content.value[] == 1.0

    inc!(c, 2.0)
    test_friendly_export_to_statsd(mock_statsd, exporter)
    @test mock_statsd.messages == Set(["counter:2.0|c"])
    @test c.content.value[] == 3.0
end

@testcase "Gauge changes" begin
    mock_statsd = MockStatsdBackend()
    r = MetricRegistry()
    g = register!(r, Gauge(1.0), "gg")
    exporter = StatsdExporter(metric_registries=Set([r]), statsd_backend=mock_statsd)

    test_friendly_export_to_statsd(mock_statsd, exporter)
    @test mock_statsd.messages == Set(["gg:1.0|g"])

    test_friendly_export_to_statsd(mock_statsd, exporter)
    @test mock_statsd.messages == Set()

    inc!(g, 2.0)
    test_friendly_export_to_statsd(mock_statsd, exporter)
    @test mock_statsd.messages == Set(["gg:3.0|g"])

    dec!(g, 0.5)
    test_friendly_export_to_statsd(mock_statsd, exporter)
    @test mock_statsd.messages == Set(["gg:2.5|g"])

    inc!(g, 55.0)
    set!(g, 0.1)
    test_friendly_export_to_statsd(mock_statsd, exporter)
    @test mock_statsd.messages == Set(["gg:0.1|g"])
end

@testcase "Changes with labels" begin
    mock_statsd = MockStatsdBackend()
    r = MetricRegistry()
    reqs = register!(r, Counter(;action=String, response_code=Int64), "requests")
    inc!(reqs; action="get", response_code=200)
    inc!(reqs; action="put", response_code=500)
    inc!(reqs; action="put", response_code=500)

    exporter = StatsdExporter(metric_registries=Set([r]), statsd_backend=mock_statsd)
    test_friendly_export_to_statsd(mock_statsd, exporter)
    @test mock_statsd.messages == Set([
        "requests:1.0|c|#action:get,response_code:200",
        "requests:2.0|c|#action:put,response_code:500",
    ])
end

@testcase "Two metrics exported" begin
    mock_statsd = MockStatsdBackend()
    r = MetricRegistry()
    c = register!(r, Counter(), "cnt")
    g = register!(r, Gauge(1.0), "gg")
    exporter = StatsdExporter(metric_registries=Set([r]), statsd_backend=mock_statsd)

    test_friendly_export_to_statsd(mock_statsd, exporter)
    @test mock_statsd.messages == Set(["gg:1.0|g", "cnt:0.0|c"])

    inc!(c, 1.0)
    test_friendly_export_to_statsd(mock_statsd, exporter)
    @test mock_statsd.messages == Set(["cnt:1.0|c"])

    set!(g, 2.0)
    test_friendly_export_to_statsd(mock_statsd, exporter)
    @test mock_statsd.messages == Set(["gg:2.0|g"])

    inc!(c, 1.0)
    set!(g, 2.1)
    test_friendly_export_to_statsd(mock_statsd, exporter)
    @test mock_statsd.messages == Set(["cnt:1.0|c", "gg:2.1|g"])
end

@testcase "StatsdExporter with default registry" begin
    clear_registry!(get_default_registry())
    mock_statsd = MockStatsdBackend()
    r = MetricRegistry()
    c1 = register!(get_default_registry(), Counter(), "cnt_default_registry")
    c2 = register!(r, Counter(), "cnt_custom_registry")
    exporter = StatsdExporter(statsd_backend=mock_statsd)
    inc!(c1, 1.0)
    inc!(c2, 1.0)
    test_friendly_export_to_statsd(mock_statsd, exporter)
    @test mock_statsd.messages == Set(["cnt_default_registry:1.0|c"])
end

@testcase "StatsdExporter spawns background thread" begin
    mock_statsd = MockStatsdBackend()
    r = MetricRegistry()
    c = register!(r, Counter(), "cnt")
    exporter = StatsdExporter(
        send_interval=Millisecond(100),
        statsd_backend=mock_statsd,
        metric_registries=Set([r]))
    @test mock_statsd.messages == Set()
    inc!(c, 1.0)
    sleep(0.2)
    @test mock_statsd.messages == Set()
    start_statsd_exporter!(exporter)
    sleep(0.5)

    @test istaskstarted(exporter.periodic_task)
    @test !istaskdone(exporter.periodic_task)
    @test mock_statsd.messages == Set(["cnt:1.0|c"])
    t = stop_statsd_exporter!(exporter)
    @test isnothing(exporter.periodic_task)
    @test istaskdone(t)
end

@testcase "StatsdExporter not exporting with send_interval=0" begin
    clear_registry!(get_default_registry())
    mock_statsd = MockStatsdBackend()
    exporter = StatsdExporter(
        send_interval=Millisecond(0),
        statsd_backend=mock_statsd)
    start_statsd_exporter!(exporter)
    @test isnothing(exporter.periodic_task)
    @test isnothing(stop_statsd_exporter!(exporter))
end

# TODO(janrous): test that the emission generally does happen with
# roughly the expected frequency by waiting and counting number of
# emissions. reset! method may set the counters back to 0 for testing
# purposes.

@testcase "StatsdExporter sends UDP packets" begin
    # Create UDP listener and then send packet to it using send(::StatsdBackend, msg)
    server = UDPSocket()
    bind(server, ip"127.0.0.1", 12346)

    client = ServerMetrics.UDPBackend(ip"127.0.0.1", 12346)
    ServerMetrics.send(client, "test message")
    @test String(recv(server)) == "test message"
    close(server)
end
