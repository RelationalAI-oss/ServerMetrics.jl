using Dates: DateTime, now
using Base.Threads: Atomic
using DataStructures: SortedDict

# Common metric building blocks

# ========================================================================================
abstract type AbstractMetricCollection end
abstract type AbstractMetric end
abstract type MetricValueContainer end
# TODO(janrous): we often want to have Union{AbstractMetric,MetricGroup} which
# could be achieved by having SingularMetric <: AbstractMetric

# Cap the number of cells per metric at 200.
# If we don't do this, faulty code could exhaust all available memory, incur significant
# cost due to monitoring storage costs (datadog) and significantly slow down metric export
# code due to massive number of cells to work through.
const MAX_CELLS_PER_METRIC = 200

const OptionalStringRef = Ref{Union{Nothing,String}}
const MetricLabels = SortedDict{Symbol,Any}

"""
    struct NumericMetric

Simple container that holds thread-safe numeric value and information about the time of the
last change as well as some metadata about the associated metric.
"""
mutable struct NumericMetric <: MetricValueContainer
    # Current value of the metric. Thread-safe.
    value::Atomic{Float64}

    # Timestamp of last change to `value`.
    # This is not guaranteed to be updated atomically with the value itself for efficiency
    # reasons. This is only used to determine which metrics have been changed recently when
    # optimizing statsd style export and monitoring systems need to work with some degree
    # of time uncertainty anyways.
    # This holds unix timestamp obtained by calling Dates.datetime2unix
    last_changed::Atomic{Float64}


    # Once the metric is associated with registry, this holds the name associated with this
    # metric.
    name::OptionalStringRef

    # Metrics can have zero or more key=value label assignments stored here.
    # For metrics that are part of the same group (collection of metrics with the
    # same name and fixed set of labels that need to be set), these should
    # uniquely identify the cell that this NumericMetric represents.
    labels::MetricLabels

    # TODO(janrous): for efficiency reasons we may precompute prometheus and statsd
    # string representation of labels.

    # TODO(janrous): we should also ensure immutability of labels, perhaps by using
    # Tuple{Pair{Symbol,Any}} instead of dict.
    function NumericMetric(v::Float64)
        return new(
            Atomic{Float64}(v),
            Atomic{Float64}(Dates.datetime2unix(now())),
            OptionalStringRef(nothing),
            MetricLabels()
        )
    end
end

"""
    inc!(m::NumericMetric, v::Float64)

Increments the current value of numeric metric `m` by `v`.
"""
function inc!(m::NumericMetric, v::Float64)
    if v < 0
        @warn "$(m.name[]): Attempted to inc! metric by negative value"
        return nothing
    end
    Base.Threads.atomic_add!(m.value, v)
    m.last_changed[] = Dates.datetime2unix(now())
    return nothing
end

"""
    dec!(m::NumericMetric, v::Number)

Decrements the current value of numeric metric `m` by `v`.
"""
function dec!(m::NumericMetric, v::Float64)
    if v < 0
        @warn "$(m.name[]): Attempted to dec! metric by negative value"
        return nothing
    end
    Base.Threads.atomic_sub!(m.value, v)
    m.last_changed[] = Dates.datetime2unix(now())
    return nothing
end

"""
    set!(m::NumericMetric, v::Float64)

Sets the current value of numeric metric `m` to `v`.
"""
function set!(m::NumericMetric, v::Float64)
    Base.Threads.atomic_xchg!(m.value, v)
    m.last_changed[] = Dates.datetime2unix(now())
    return nothing
end

"""
    set_counter!(m::NumericMetric, v::Float64)

Sets the current value of NumericMetric `m` to `v` but only if the new value is greater
than the current value. This enforces counter monotonicity but allows for exposing things
that are already "tracked as a counter" internally and for which we do not have direct
access to increments (e.g. gc allocation counts).
"""
function set_counter!(m::NumericMetric, v::Float64)
    old_v = Base.Threads.atomic_max!(m.value, v)
    if old_v < v
        m.last_changed[] = Dates.datetime2unix(now())
    end
    return nothing
end


"""
    validate_metric_name(name::String)

Ensures that the metric meets datadog and prometheus naming requirements.

For more information, see:
- https://prometheus.io/docs/practices/naming/
- https://docs.datadoghq.com/developers/metrics/
- https://docs.datadoghq.com/developers/guide/what-best-practices-are-recommended-for-naming-metrics-and-tags/
"""
function validate_metric_name(name::String)
    if !isletter(name[1])
        throw(ArgumentError("Metric name must begin with a letter: $name"))
    end
    if !isascii(name)
        throw(ArgumentError("Metric name contains non-ASCII characters: $name"))
    end
    if length(name) > 200
        throw(
            ArgumentError(
                "Metric name is too long. Limit is 200 characters; provided name is $(length(name)) characters: $name",
            ),
        )
    end
    if !occursin(r"^[a-zA-Z_:][a-zA-Z0-9_:]*$", name)
        throw(ArgumentError("Metric name does not meet prometheus naming restrictions: $name"))
    end
    return nothing
end

struct MetricGroup <: MetricValueContainer
    # Synchronizes access to cells
    lock::ReentrantLock

    # cells contain individual NumericMetrics, keys are Dict(:label => String(value)).
    cells::Dict{MetricLabels,NumericMetric}

    # This specifies all labels associated with this group and their types.
    label_types::Dict{Symbol,Type}

    # This holds name of the metric once registered.
    name::OptionalStringRef

    default_value::Float64

    function MetricGroup(default_value::Float64 = 0.0; kwargs...)
        # Label name correctness is asserted at registration time and not here.
        return new(
            ReentrantLock(),
            Dict(),
            convert(Dict{Symbol,Type}, kwargs),
            nothing,
            default_value
        )
    end
end

dimension(mg::MetricGroup) = length(mg.label_types)

# This represents invalid cell and is passed to inc!, dec!, set! functions to trigger
# errors to be logged instead of exceptions being thrown.
struct DummyCell <: MetricValueContainer
    associated_with::MetricValueContainer
    label_assignments::Dict{Symbol,Any}
end

function log_invalid_metric_usage(m::DummyCell, fn::String)
    # TODO(janrous): this should throw an exception in test environment and use @error
    # logging in production. A more detailed reason why the access is invalid (e.g.
    # type error, unknown labels or missing labels) could be emitted here to make debugging
    # easier.
    # A problem with each label can be either: 1. wrong type, 2. unknown label, 3. missing
    # value assignment.
    lab=join(["$k=$v" for (k,v) in m.label_assignments], ", ")
    @error "$fn($(m.associated_with.name[]); $(lab)): invalid labels requested."
end

inc!(m::DummyCell, v::Float64) = log_invalid_metric_usage(m, "inc!")
dec!(m::DummyCell, v::Float64) = log_invalid_metric_usage(m, "dec!")
set!(m::DummyCell, v::Float64) = log_invalid_metric_usage(m, "set!")
set_counter!(m::DummyCell, v::Float64) = log_invalid_metric_usage(m, "set_counter!")

function get_cell!(m::NumericMetric; labels...)
    if length(labels) > 0
        return DummyCell(m, labels)
    end
    return m
end

# Returns true if labels assign value of correct type to all known labels of `mg`.
function labels_are_valid(mg::MetricGroup, labels)
    if length(labels) != dimension(mg)
        return false
    end
    for (name, value) in labels
        ltype = get(mg.label_types, name, nothing)
        if ltype === nothing || !isa(value, ltype)
            return false
        end
    end
    return true
end

function get_cell!(mg::MetricGroup; labels...)
    if !labels_are_valid(mg, labels)
        return DummyCell(mg, labels)
    end
    cell_key = convert(MetricLabels, labels)
    Base.@lock mg.lock begin
        # Retrieve cell or construct new one if this doesn't exist.
        return_cell = get!(mg.cells, cell_key) do
            # TODO(janrous): simplify by having value, name, labels constructor for NumericMetric
            new_cell = NumericMetric(mg.default_value)
            new_cell.name = mg.name[]
            new_cell.labels = cell_key
            mg.cells[cell_key] = new_cell
            return new_cell
        end
        _maintain_cell_limits(mg, return_cell)
        return return_cell
    end
end

# This function ensures that MetricGroup has no more than MAX_CELLS_PER_METRIC at all
# times by removing the least recently used cell (skipping the req_cell to ensure safe return).
function _maintain_cell_limits(mg::MetricGroup, req_cell::MetricValueContainer)
    if length(mg.cells) <= MAX_CELLS_PER_METRIC
        return nothing
    end
    # Finding LRU cell is O(MAX_CELLS_PER_METRICS). If this ever becomes performance
    # bottleneck, we might consider semi-random strategy. However, we should not be
    # really hitting this limit anyways if we use metrics in a reasonable manner.
    @warn "Metric $(mg.name[]) has too many cells. Discarding oldest cell."
    local lru_timestamp = nothing
    local lru_cell_key = nothing
    for (cell_key, cell) in mg.cells
        cell == req_cell && continue  # Do not discard the newly created/requested cell.
        if lru_timestamp === nothing || lru_timestamp > cell.last_changed[]
            lru_timestamp = cell.last_changed[]
            lru_cell_key = cell_key
        end
    end
    if lru_cell_key !== nothing
        delete!(mg.cells, lru_cell_key)
    end
end

get_cell!(mg::AbstractMetric; labels...) = get_cell!(mg.content; labels...)

# inc!, dec! and set! on MetricGroup dispatch the call to the right cell
inc!(mg::MetricGroup, v::Float64; labels...) = inc!(get_cell!(mg; labels...), v)
dec!(mg::MetricGroup, v::Float64; labels...) = dec!(get_cell!(mg; labels...), v)
set!(mg::MetricGroup, v::Float64; labels...) = set!(get_cell!(mg; labels...), v)
set_counter!(mg::MetricGroup, v::Float64; lbl...) = set_counter!(get_cell!(mg; lbl...), v)

"""
    validate_metric_labels(m::AbstractMetric)

Verifies that all metric label names meet prometheus and statsd requirements.
This effectively calls `validate_metric_name` on all label names and throws exceptions if
the requirements are not met.
"""
function validate_metric_labels(mg::MetricGroup)
    for label_name in keys(mg.label_types)
        validate_metric_name(String(label_name))
    end
    return nothing
end

"""
    struct Gauge <: AbstractMetric
Gauge is a metric that holds an arbitrary value that can be incremented, decremented or set
to arbitrary value.
"""
struct Gauge <: AbstractMetric
    content::MetricValueContainer
    function Gauge(value::Float64; kwargs...)
        if length(kwargs) > 0
            return new(MetricGroup(value; kwargs...))
        else
            return new(NumericMetric(value))
        end
    end
end
Gauge(v::Number; kwargs...) = Gauge(convert(Float64, v); kwargs...)
Gauge(;kwargs...) = Gauge(0.0; kwargs...)

inc!(m::Gauge, v::Float64; labels...) = inc!(m.content, v; labels...)
dec!(m::Gauge, v::Float64; labels...) = dec!(m.content, v; labels...)
set!(m::Gauge, v::Float64; labels...) = set!(m.content, v; labels...)

"""
    struct Counter <: AbstractMetric

Counter is a metric with monotonically increasing value that never decreases.

Value of a counter may be reset to zero upon server restarts.
"""
struct Counter <: AbstractMetric
    content::MetricValueContainer
    # Contains last emitted value for each cell.
    # This is expected to be only manipulated by statsd-exporter and as such doesn't need
    # to be thread-safe.
    last_emitted_values::Dict{Any, Float64}

    function Counter(;kwargs...)
        if length(kwargs) > 0
            return new(MetricGroup(;kwargs...), Dict())
        else
            return new(NumericMetric(0.0), Dict())
        end
    end
end

inc!(m::Counter, v::Float64; labels...) = inc!(m.content, v; labels...)
set_counter!(m::Counter, v::Float64; labels...) = set_counter!(m.content, v; labels...)

# Useful shorthands for the metric modification methods.

# By default we want to increment or decrement by one.
inc!(m::AbstractMetric; labels...) = inc!(m, 1.0; labels...)
dec!(m::AbstractMetric; labels...) = dec!(m, 1.0; labels...)

# We want to be able to use arbitrary numbers that will be converted to floats here.
inc!(m::AbstractMetric, v::Number; labels...) = inc!(m, convert(Float64, v); labels...)
dec!(m::Gauge, v::Number; labels...) = dec!(m, convert(Float64, v); labels...)
set!(m::Gauge, v::Number; labels...) = set!(m, convert(Float64, v); labels...)
set_counter!(m::Counter, v::Number; lbl...) = set_counter!(m, convert(Float64, v); lbl...)

"""
    get_cells(m::AbstractMetric)

Returns list of NumericMetric for each cell associated with this metric.
"""
get_cells(m::AbstractMetric) = _get_cells(m.content)
_get_cells(x) = [x]
_get_cells(content::MetricGroup) = collect(values(content.cells))

# TODO(janrous): MetricGroup{T} currently supports arbitrary symbols for label
# names and arbitrary types for label values. We might want to enforce some
# stricter rules for MetricGroup{T} that will be registered and exported.

"""
    struct MetricRegistry

MetricRegistry is a collection of named metrics. Contents of registry can then be exported
to variety of monitoring systems (currently supported are prometheus and datadog).

Individual metrics can be associated with registry using the `register!` method.

Collection of metrics (subclass of `AbstractMetricCollection`) can be associated with
registry using `register_collection!` method.

When a collection is registered, the field name of each metric within the collection struct becomes the name of the exported metric.

Example:
The following code will register two metrics named `my_counter` and `my_gauge` with registry
`reg`:

```julia
Base.@kwdef struct MyMetrics <: AbstractMetricCollection
    my_counter = Counter()
    my_gauge = Gauge()
end
metrics = MyMetrics()
register_collection!(reg, metrics)
```

MetricRegistry enforces that metric names are unique within a registry and that metric names
adhere to the requirements of the supported monitoring backends.
"""
struct MetricRegistry
    lock::ReentrantLock
    metrics::SortedDict{String,AbstractMetric}

    MetricRegistry() = new(ReentrantLock(), Dict{String,AbstractMetric}())
end

# Shorthand constructor registers metric collection `col` with the new registry.
function MetricRegistry(col)
    r = MetricRegistry()
    register_collection!(r, col)
    return r
end

# Default registry is intended for standard production monitoring metrics.
# Contents of the default registry should be accessible at /metrics http
# endpoint and should be periodically exported to statsd backend.
#
# This global variable is a singleton that is instantiated once `get_default_registry`
# is called for the first time.
const __DEFAULT_REGISTRY__ = Ref{Union{Nothing,MetricRegistry}}(nothing)
const __DEFAULT_REGISTRY_LOCK__ = Base.ReentrantLock()

"""
    get_default_registry()

Returns (and optionally constructs) the default MetricRegistry instance. This method ensures
that there is only one (singleton) instance of the default registry used across all modules
that use server metrics instrumentation. This singleton instance is constructed on the first
call to this method.
"""
function get_default_registry()
    if __DEFAULT_REGISTRY__[] === nothing
        Base.@lock __DEFAULT_REGISTRY_LOCK__ begin
            if __DEFAULT_REGISTRY__[] === nothing
                __DEFAULT_REGISTRY__[] = MetricRegistry()
            end
        end
    end
    return __DEFAULT_REGISTRY__[]
end

function set_metric_name!(m::AbstractMetric, name::String)
    if m.content.name[] === nothing
        m.content.name[] = name
    elseif m.content.name[] != name
        throw(AssertionError(
            "$(m.content.name[]): Metric can't be registered with different names."
        ))
    end
    return nothing
end
name(m::AbstractMetric) = m.content.name[]
name(m::MetricValueContainer) = m.name[]

"""
    register!(r::MetricRegistry, m::AbstractMetric)

Registers metric `m` with the registry `r` assigning it given `name`.

`name` must meet the naming constrains for statsd and prometheus backends as specified in
`validate_metric_name`.
"""
function register!(r::MetricRegistry, m::AbstractMetric, name::String; overwrite::Bool=false)
    validate_metric_name(name)
    isa(m.content, MetricGroup) && validate_metric_labels(m.content)

    Base.@lock r.lock begin
        if haskey(r.metrics, name)
            if overwrite
                @warn "Metric $(name) registered multiple times, overwriting existing one."
            else
                throw(KeyError("Metric name $(name) already registered"))
            end
        end
        set_metric_name!(m, name)
        r.metrics[name] = m
    end
    return m
end
register!(m::AbstractMetric, name::String) = register!(get_default_registry(), m, name)

"""
    unregister!(r::MetricRegister, name::String)

unregisters (dissociates) metric of a given `name` from the registry `r`.
"""
function unregister!(r::MetricRegistry, name::String)
    Base.@lock r.lock begin
        if !haskey(r.metrics, name)
            throw(KeyError("Metric $name not found in the registry"))
        end
        m = r.metrics[name]
        delete!(r.metrics, name)
    end
end

"""
    clear_registry!(r::MetricRegistry)

Removes all metrics from registry `r`.
"""
function clear_registry!(r::MetricRegistry)
    Base.@lock r.lock begin
        empty!(r.metrics)
    end
end

"""
    register_collection!(r::MetricRegistry, c::AbstractMetricCollection)

Registers metric contained within structure `stuff` with the registry `r`. The names of the
fields within the struct will be used as metric names when registering.
registry.
"""
function register_collection!(r::MetricRegistry, stuff::Any; overwrite::Bool = false)
    for prop_name in fieldnames(typeof(stuff))
        metric = getproperty(stuff, prop_name)
        if metric isa AbstractMetric
            register!(r, metric, String(prop_name); overwrite=overwrite)
        end
    end
    return nothing
end

"""
    publish_metrics_from(c::AbstractMetricCollection)

Registers metrics contained within `c` with the default registry. This effectively results
in these metrics being published to the production monitoring systems.
"""
publish_metrics_from(c; kwargs...) = register_collection!(get_default_registry(), c; kwargs...)

"""
    get_metric(r::MetricRegistry, name::String)

Retrieves metric of a given `name` from registry `r`. Throws `KeyError` if metric of a given
`name` is not found in the registry.
"""
function get_metric(r::MetricRegistry, name::String)
    Base.@lock r.lock begin
        return r.metrics[name]
    end
end

# TODO(janrous): Integrate this with latency-tracking metrics once they exist.
# See https://github.com/RelationalAI/raicode/issues/4372
macro time_ms(ex)
    quote
        local elapsedtime = time_ns()
        $(esc(ex))
        (time_ns() - elapsedtime) / 1000000.0
    end
end

get_cell_if_exists(m::NumericMetric; labels...) = isempty(labels) ? m : nothing

function get_cell_if_exists(m::MetricGroup; labels...)
    if !labels_are_valid(m, labels)
        return nothing
    end
    Base.@lock m.lock begin
        return get(m.cells, convert(MetricLabels, labels), nothing)
    end
end
get_cell_if_exists(m::AbstractMetric; labels...) = get_cell_if_exists(m.content; labels...)

"""
    value_of(r::MetricRegistry, name::String; labels...)

Retrieve the value of a metric registered in `r` under `name`. For metrics that use labels,
their values should be set in `labels...`. In case the metric doesn't exist or
the metric doesn't have the specified cell (either due to nonexistence or invalid
labels), this function will return `nothing`. Otherwise, a Float64 representing
the current value will be returned.
"""
function value_of(r::MetricRegistry, name::String; labels...)
    try
        cell = get_cell_if_exists(get_metric(r, name); labels...)
        return cell.value[]
    catch
        return nothing
    end
end

value_of(name::String; labels...) = value_of(get_default_registry(), name; labels...)

function zero_all_metrics(r::MetricRegistry)
    for m in values(r.metrics)
        m.content.value[] = 0.0
    end
    return nothing
end
zero_all_metrics() = zero_all_metrics(get_default_registry())
