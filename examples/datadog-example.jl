using ServerMetrics
using Dates

statsd_exporter = ServerMetrics.StatsdExporter(
    statsd_backend=ServerMetrics.UDPBackend("127.0.0.1", 8125),
    send_interval=Dates.Second(1)
)

Base.@kwdef struct UptimeMetrics <: AbstractMetricCollection
    server_uptime_seconds = Gauge()
    server_heartbeats_total = Counter()
end

@info "Starting statsd exporter"
ServerMetrics.start_statsd_exporter!(statsd_exporter)

metrics = UptimeMetrics()
ServerMetrics.publish_metrics_from(metrics; overwrite=true)
startup_timestamp = Dates.datetime2unix(Dates.now())
ServerMetrics.@spawn_sticky_periodic_task "UptimeTracker" Dates.Second(1) begin
    time_delta = Dates.datetime2unix(Dates.now()) - startup_timestamp
    set!(metrics.server_uptime_seconds, time_delta)
    inc!(metrics.server_heartbeats_total)
end

sleep(10)
@info "Stopping statsd exporter"
ServerMetrics.stop_statsd_exporter!(statsd_exporter)
