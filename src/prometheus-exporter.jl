# Print contents of the default_registry in a Prometheus text format
import HTTP
import Base

metric_type(m::Gauge) = "gauge"
metric_type(m::Counter) = "counter"
metric_type(m::ServerMetrics.AbstractMetric) = nothing

# Escapes special characters (", \, \n) in label value string representation.
function escape_label_value(v::Any)
    return replace(
        replace(replace("$v", "\\" => "\\\\"), "\"" => "\\\""),
        "\n" => "\\\n"
    )
end

function labels_to_string(labels::MetricLabels)
    if Base.isempty(labels)
        return ""
    end
    kv = join(["$k=\"$(escape_label_value(v))\"" for (k, v) in labels], ",")
    return "{$kv}"
end

function print_metric(b::Base.IOBuffer, m::AbstractMetric)
    println(b, "# TYPE $(name(m)) $(metric_type(m))")
    # TODO(janrous): sorting of cells and conversion of labels key=values
    # to string happens repeatedly here. We could optimize this by e.g.
    # caching the string representation of these and perhaps using SortedDict
    # to hold the cells, but this does not seem to be possible if the cell
    # keys are SortedDict{Symbol,Any}.
    # There are several factors that may make this a non-issue, specifically:
    # - we are not actually using prometheus to scrape this at all
    # - we may be exporting small number of metrics with small number of
    #   cells each (sort complexity)
    # - we may be only scraping the server infrequently so redoing this work
    #   may be okay.
    cells_with_labels = SortedDict{String,NumericMetric}(
        labels_to_string(cell.labels) => cell
        for cell in get_cells(m)
    )
    for (label_str, cell) in cells_with_labels
        println(b, "$(name(m))$label_str $(cell.value[])")
    end
    println(b)
end

"""
    handle_metrics()

This http handler renders contents of the _default registry_ in a prometheus-compatible text
format.

This can be registered to `/metrics` HTTP endpoint to enable integration with prometheus
monitoring system.
"""
function handle_metrics()
    buffer = Base.IOBuffer()
    registry = get_default_registry()
    for (name, metric) in registry.metrics
        print_metric(buffer, metric)
        # Values of metrics may not come from the exact same timepoint
        # but that's okay because we are not relying on that behavior
        # in any way.
        # What matters is the change between two sampling periods and
        # that is going to work reasonably well.
    end
    HTTP.Response(String(take!(buffer)))
    # TODO(janrous): we may consider streaming to avoid buffering the
    # entire (potentially large) response in memory.
end
