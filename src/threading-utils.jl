import Dates
using Base: Semaphore
using Base.Threads: Atomic, @spawn, Condition
using Dates: Period

function catch_stack_to_string(catch_stack)
    buf = IOBuffer()
    Base.display_error(buf, catch_stack)
    return String(take!(buf))
end
function restore_callsite_source_position!(expr, src)
    # because the logging macros call functions in this package, the source file+line are
    # incorrectly attributed to the wrong location, so we explicitly override the source
    # with the original value
    expr.args[1].args[2] = src
    return expr
end
macro error_with_catch_stack(msg, exs...)
    return restore_callsite_source_position!(esc(:(
        $Base.@error string($msg, "\n", catch_stack_to_string($Base.catch_stack())) $(exs...)
        )), __source__)
end

"""
    @spawn_with_error_log expr
    @spawn_with_error_log "..error msg.." expr
Exactly like `@spawn`, except that it wraps `expr` in a try/catch block that will print any
exceptions that are thrown from the `expr` to stderr, via `@error`. You can
optionally provide an error message that will be printed before the exception is displayed.
This is useful if you need to spawn a "background task" whose result will never be
waited-on nor fetched-from.
"""
macro spawn_with_error_log(expr)
    _spawn_with_error_log_expr(expr)
end
macro spawn_with_error_log(message, expr)
    _spawn_with_error_log_expr(expr, message)
end
function _spawn_with_error_log_expr(expr, message = "")
    e = gensym("err")
    return esc(
        quote
            $Base.Threads.@spawn try
                $(expr)
            catch $e
                $TransactionLogging.@error_with_catch_stack "@spawn_with_error_log failed:"
                rethrow()
            end
        end
    )
end

"""
    PeriodicTask
This structure is a wrapper around background periodic Task and can be used to inspect the
state of the task itself and to safely terminate the background periodic task by signalling
via `should_terminate`.
"""
struct PeriodicTask
    # Name of the periodic task. Attached to error logs for debuggability.
    name::String

    # Specifies how often the underlying periodic task should be run.
    period::Period

    # When set to true, the underlying periodic task will terminate before next
    # iteration.
    should_terminate::Atomic{Bool}

    # This is used by the task to wait until `period` elapses and is used
    # in stop_periodic_task! to quickly wake-up and terminate sleeping task.
    condition::Condition

    # The underlying periodic task itself.
    task::Task
end

"""
    @spawn_periodic_task period expr name
Run `expr` once every `period` and returns `PeriodicTask` that will carry out this logic. The task
can be terminated by calling `stop_periodic_task!`. Optional `name` can be specified and
this will be attached to error logs and (eventually) metrics for easier debuggability.
`period` must be a `Dates.Period`.
# Examples
```julia
import Dates
disk_stuff = DiskStuff()
my_task = @spawn_periodic_task Dates.Seconds(30) dump_some_stuff_to_disk(disk_stuff) "DiskDumper"
# ... do some stuff ...
stop_periodic_task!(my_task)
istaskfailed(my_task) && throw(SystemError("Periodic task has failed!!"))
```
"""
macro spawn_periodic_task(period, expr, name="Unnamed")
    # TODO(janrous): add number of iteratons, number of failures and last successful
    # iteration timestamp once metrics with labels are available.
    return quote
        should_terminate = Atomic{Bool}(false)
        cond = Condition()
        # TODO(janrous): we can improve the timing precision by calculating how
        # much time has elapsed since last_execution when we are about to enter
        # sleep and subtract that from period.
        task = @spawn begin
            while !should_terminate[]
               Base.@lock cond begin
                   # Spawn notifier to wake us up when it's time to run.
                    @spawn begin
                        sleep($(esc(period)))
                        Base.@lock cond notify(cond)
                    end
                    wait(cond)
                    should_terminate[] && continue
                    try
                        $(esc(expr))
                    catch err
                        @error_with_catch_stack "$($(esc(name))): periodic task failed"
                    end
                end
            end
        end
        # TODO: if name is not given, use module:lineno of the caller
        PeriodicTask($(esc(name)), $(esc(period)), should_terminate, cond, task)
    end
end

macro spawn_sticky_periodic_task(name, period, expr)
    return quote
        should_terminate = Atomic{Bool}(false)
        cond = Condition()
        # This version uses @async instead of @spawn to ensure that tasks are run
        # on the current thread in a "sticky" mode. This is intended to be used
        # with the high priority julia patch that moves all generic task handling
        # from the thread that calls this macro.
        task = @async begin
            @info "Scheduled sticky periodic task $($(esc(name))) on thread $(Threads.threadid())"
            while !should_terminate[]
               Base.@lock cond begin
                   # Spawn notifier to wake us up when it's time to run.
                    @async begin
                        sleep($(esc(period)))
                        Base.@lock cond notify(cond)
                    end
                    wait(cond)
                    should_terminate[] && continue
                    try
                        $(esc(expr))
                    catch err
                        @error_with_catch_stack "$($(esc(name))): periodic task failed"
                    end
                end
            end
        end
        PeriodicTask($(esc(name)), $(esc(period)), should_terminate, cond, task)
    end
end

"""
    stop_periodic_task!(task::PeriodicTask)
Triggers termination of the periodic task.
"""
function stop_periodic_task!(task::PeriodicTask)
    task.should_terminate[] = true
    Base.@lock task.condition notify(task.condition)
    wait(task.task)
    return task
end

# Reflection methods for the inner ::Task struct.
Base.istaskdone(t::PeriodicTask) = istaskdone(t.task)
Base.istaskfailed(t::PeriodicTask) = istaskfailed(t.task)
Base.istaskstarted(t::PeriodicTask) = istaskstarted(t.task)
