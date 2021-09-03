using ServerMetrics
using HTTP
using Dates

Base.@kwdef struct UptimeMetrics <: AbstractMetricCollection
    server_uptime_seconds = Gauge()
    server_heartbeats_total = Counter()
end

metrics = UptimeMetrics()
ServerMetrics.publish_metrics_from(metrics; overwrite=true)
startup_timestamp = Dates.datetime2unix(Dates.now())
ServerMetrics.@spawn_sticky_periodic_task "UptimeTracker" Dates.Second(1) begin
    time_delta = Dates.datetime2unix(Dates.now()) - startup_timestamp
    set!(metrics.server_uptime_seconds, time_delta)
    inc!(metrics.server_heartbeats_total)
end

HTTP.serve() do http_request
    ServerMetrics.handle_metrics(http_request)
end
