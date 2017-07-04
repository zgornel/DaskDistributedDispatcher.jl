const no_value = "--no-value-sentinel--"

const IN_PLAY = ("waiting", "ready", "executing")
const PENDING = ("waiting", "ready", "constrained")
const PROCESSING = ("waiting", "ready", "constrained", "executing")
const READY = ("ready", "constrained")


"""
    Worker

A `Worker` represents a worker endpoint in the distributed cluster that accepts instructions
from the scheduler, fetches dependencies, executes compuations, stores data, and
communicates state to the scheduler.
"""
type Worker
    # Communication management
    scheduler_address::URI
    host::IPAddr
    port::Integer
    listener::Base.TCPServer
    batched_stream::Nullable{BatchedSend}
    scheduler::Rpc
    handlers::Dict{String, Function}
    target_message_size::AbstractFloat

    # Data and resource management
    available_resources::Dict{String, Integer}
    data::Dict{String, Any}  # Maps keys to the results of function calls
    futures::Dict{String, DeferredFutures.DeferredFuture}
    priorities::Dict{String, Tuple}
    priority_counter::Integer
    nbytes::Dict{String, Integer}
    types::Dict{String, Type}
    durations::Dict{String, AbstractFloat}
    who_has::Dict{String, Set{String}}
    has_what::DefaultDict{String, Set{String}}

    # Task management
    tasks::Dict{String, Tuple}
    task_state::Dict{String, String}

    # Task state management
    transitions::Dict{Tuple{String, String}, Function}
    ready::PriorityQueue{String, Tuple, Base.Order.ForwardOrdering}
    constrained::Deque{String}
    data_needed::Deque{String}
    executing::Set{String}
    long_running::Set{String}

    # Dependency management
    dep_transitions::Dict{Tuple{String, String}, Function}
    dep_state::Dict{String, String}
    dependencies::Dict{String, Set}
    dependents::Dict{String, Set}
    waiting_for_data::Dict{String, Set}
    pending_data_per_worker::DefaultDict{String, Deque{String}}
    resource_restrictions::Dict{String, Dict}

    # Peer communication
    in_flight_tasks::Dict{String, String}
    in_flight_workers::Dict{String, Set{String}}
    total_connections::Integer  # The maximum number of concurrent connections allowed
    suspicious_deps::DefaultDict{String, Integer}
    missing_dep_flight::Set{String}

    # Logging information
    is_computing::Bool
    status::String
    executed_count::Integer
    log::Deque{Tuple}
    exceptions::Dict{String, String}
    tracebacks::Dict{String, String}
    startstops::DefaultDict{String, Array}

    # Validation
    validate::Bool
end

"""
    Worker(scheduler_address::String)

Creates a `Worker` that listens on a random port for incoming messages.
"""
function Worker(scheduler_address::String)
    port = rand(1024:9000)
    scheduler_address = build_URI(scheduler_address)

    # This is the minimal set of handlers needed
    # https://github.com/JuliaParallel/Dagger.jl/issues/53
    handlers = Dict{String, Function}(
        "compute-stream" => compute_stream,
        "get_data" => get_data,
        "gather" => gather,
        "delete_data" => delete_data,
        "terminate" => terminate,
        "keys" => get_keys,
    )
    transitions = Dict{Tuple{String, String}, Function}(
        ("waiting", "ready") => transition_waiting_ready,
        ("waiting", "memory") => transition_waiting_memory,
        ("ready", "executing") => transition_ready_executing,
        ("ready", "memory") => transition_ready_memory,
        ("constrained", "executing") => transition_constrained_executing,
        ("executing", "memory") => transition_executing_done,
        ("executing", "error") => transition_executing_done,
    )
    dep_transitions = Dict{Tuple{String, String}, Function}(
        ("waiting", "flight") => transition_dep_waiting_flight,
        ("waiting", "memory") => transition_dep_waiting_memory,
        ("flight", "waiting") => transition_dep_flight_waiting,
        ("flight", "memory") => transition_dep_flight_memory,
    )
    worker = Worker(
        scheduler_address,
        getipaddr(),  # host
        listenany(port)...,  # port and listener
        nothing, #  batched_stream
        Rpc(scheduler_address),  # scheduler
        handlers,
        50e6,  # target_message_size = 50 MB

        Dict{String, Integer}(),  # available_resources
        Dict{String, Any}(),  # data
        Dict{String, DeferredFutures.DeferredFuture}(), # futures
        Dict{String, Tuple}(),  # priorities
        0,  # priority_counter
        Dict{String, Integer}(),  # nbytes
        Dict{String, Type}(),  # types
        Dict{String, AbstractFloat}(),  # durations
        Dict{String, Set{String}}(),  # who_has
        DefaultDict{String, Set{String}}(Set{String}),  # has_what

        Dict{String, Tuple}(),  # tasks
        Dict{String, String}(),  #task_state

        transitions,
        PriorityQueue(String, Tuple, Base.Order.ForwardOrdering()),  # ready
        Deque{String}(),  # constrained
        Deque{String}(),  # data_needed
        Set{String}(),  # executing
        Set{String}(),  # long_running

        dep_transitions,
        Dict{String, String}(),  # dep_state
        Dict{String, Set}(),  # dependencies
        Dict{String, Set}(),  # dependents
        Dict{String, Set}(),  # waiting_for_data
        DefaultDict{String, Deque{String}}(Deque{String}),  # pending_data_per_worker
        Dict{String, Dict}(),  # resource_restrictions

        Dict{String, String}(),  # in_flight_tasks
        Dict{String, Set{String}}(),  # in_flight_workers
        50,  # total_connections
        DefaultDict{String, Integer}(0),  # suspicious_deps
        Set{String}(),  # missing_dep_flight

        false,  # is_computing
        "starting",  # status
        0,  # executed_count
        Deque{Tuple}(),  # log
        Dict{String, String}(),  # exceptions
        Dict{String, String}(),  # tracebacks
        DefaultDict{String, Array}(Array{Any, 1}),  # startstops

        true,  # validation
    )

    start_worker(worker)
    return worker
end

##############################       ADMIN FUNCTIONS        ##############################

"""
    address(worker::Worker)

Returns this Workers's address formatted as an URI.
"""
address(worker::Worker) = return chop(string(build_URI(worker.host, worker.port)))

"""
    show(io::IO, worker::Worker)

Prints a representation of the worker and it's state.
"""
function Base.show(io::IO, worker::Worker)
    @printf(
        io,
        "<%s: %s, %s, stored: %d, running: %d, ready: %d, comm: %d, waiting: %d>",
        typeof(worker).name.name, address(worker), worker.status,
        length(worker.data), length(worker.executing),
        length(worker.ready), length(worker.in_flight_tasks),
        length(worker.waiting_for_data),
    )
end

"""
    start_worker(worker::Worker)

Coordinates a worker's startup.
"""
function start_worker(worker::Worker)
    @assert worker.status == "starting"

    start_listening(worker)

    info(
        logger,
        "Start worker at: $(address(worker)), " *
        "waiting to connect to: $(chop(string(worker.scheduler_address)))."
    )

    register_worker(worker)
end

"""
    register_worker(worker::Worker)

Registers a `Worker` with the dask-scheduler process.
"""
function register_worker(worker::Worker)
    @async begin
        response = send_recv(
            worker.scheduler,
            Dict(
                "op" => "register",
                "address" => address(worker),
                "ncores" => Sys.CPU_CORES,
                "keys" => collect(keys(worker.data)),
                "nbytes" => worker.nbytes,
                "now" => time(),
                "executing" => length(worker.executing),
                "in_memory" => length(worker.data),
                "ready" => length(worker.ready),
                "in_flight" => length(worker.in_flight_tasks),
            )
        )
        try
            @assert response == "OK"
            worker.status = "running"
        catch
            error("An error ocurred on the dask-scheduler while registering this worker.")
        end
    end
end

"""
    start_listening(worker::Worker)

Listens for incoming connections on a random port initialized on startup.
"""
function start_listening(worker::Worker)
    @async begin
        while true
            sock = accept(worker.listener)
            debug(logger, "New connection received")
            @async listen_for_incoming_msgs(worker, sock)
        end
    end
end

"""
    listen_for_incoming_msgs(worker::Worker, sock::TCPSocket)

Listens for incoming messages on an established connection.
"""
function listen_for_incoming_msgs(worker::Worker, sock::TCPSocket)
    while isopen(sock)
        try
            msgs = recv_msg(sock)
            debug(logger, "Message received: $msgs")

            @async begin
                if isa(msgs, Array)
                    for msg in msgs
                        handle_incoming_msg(worker, sock, msg)
                    end
                else
                    handle_incoming_msg(worker, sock, msgs)
                end
            end
        catch exception
            isa(exception, EOFError) || rethrow(exception)
        end
    end
    debug(logger, "Connection closed")
    close(sock)
end


"""
    Base.close(worker::Worker)

Closes the worker and all the connections it has open.
"""
function Base.close(worker::Worker)
    if worker.status ∉ ("closed", "closing")
        info(logger, "Stopping worker at $(address(worker))")

        worker.status = "closing"

        close(worker.scheduler)
        close(worker.batched_stream)
        close(worker.listener)

        worker.status = "closed"
    end
end

"""
    handle_incoming_msg(worker::Worker, comm::TCPSocket, msg::Dict)

Handle message received by the worker.
"""
function handle_incoming_msg(worker::Worker, comm::TCPSocket, msg::Dict)
    @async begin
        op = pop!(msg, "op", nothing)
        reply = pop!(msg, "reply", nothing)
        terminate = pop!(msg, "close", nothing)

        haskey(msg, "key") && validate_key(msg["key"])
        msg = Dict(parse(k) => v for (k,v) in msg)

        if worker.is_computing && !haskey(worker.handlers, op)
                if op == "close"
                    closed = true
                    close(worker)
                    return
                elseif op == "compute-task"
                    add_task(worker, ;msg...)
                elseif op == "release-task"
                    push!(worker.log, (msg[:key], "release-task"))
                    release_key(worker, ;msg...)
                elseif op == "delete-data"
                    delete_data(worker, ;msg...)
                else
                    warn(logger, "Unknown operation $op, $msg")
                end

                worker.priority_counter -= 1

                ensure_communicating(worker)
                ensure_computing(worker)
        else
            try
                handler = worker.handlers[op]
                handler(worker, comm, ;msg...)

            catch exception
                error("No handler found for $op: $exception")
            end
        end
    end
end

##############################       HANDLER FUNCTIONS        ##############################

"""
    compute_stream(worker::Worker, comm::TCPSocket)

Set `is_computing` to true so that the worker can manage state, and starts a batched
communication stream to the scheduler.
"""
function compute_stream(worker::Worker, comm::TCPSocket)
    @async begin
        worker.is_computing = true
        worker.batched_stream = BatchedSend(comm, interval=0.002)
    end
end

"""
    get_data(worker::Worker, comm::TCPSocket; keys::Array=[], who::String="")

Sends the results of `keys` back over the stream they were requested on.
"""
function get_data(worker::Worker, comm::TCPSocket; keys::Array=[], who::String="")
    @async begin
        data = Dict(
            to_key(k) =>
            to_serialize(worker.data[k]) for k in filter(k -> haskey(worker.data, k), keys)
        )
        send_msg(comm, data)
        push!(worker.log, ("get_data", keys, who))
    end
end

"""
    gather(worker::Worker, comm::TCPSocket)

Gathers the results for various keys.
"""
function gather(worker::Worker, comm::TCPSocket)
    warn(logger, "Not implemented `gather` yet")
end

"""
    delete_data(worker::Worker, comm::TCPSocket; keys::Array=[], report::String="true")

Deletes the data associated with each key of `keys` in `worker.data`.
"""
function delete_data(worker::Worker, comm::TCPSocket; keys::Array=[], report::String="true")
    @async begin
        for key in keys
            debug(logger, "Delete key: $key")
            haskey(worker.task_state, key) && release_key(worker, key=key)
            haskey(worker.dep_state, key) && release_dep(worker, key)
        end

        debug(logger, "Deleted $(length(keys)) keys")
        if report == "true"
            debug(logger, "Reporting loss of keys to scheduler")
            msg = Dict(
                "op" => "remove-keys",
                "address" => address(worker),
                "keys" => [to_key(key) for key in keys],
            )
            send_msg(worker.scheduler, msg)
        end
    end
end

"""
    terminate(worker::Worker, comm::TCPSocket, msg::Dict)

Shutdown the worker and close all its connections.
"""
function terminate(worker::Worker, comm::TCPSocket, msg::Dict)
    warn(logger, "Not implemented `terminate` yet")
end

"""
    get_keys(worker::Worker, comm::TCPSocket, msg::Dict) -> Array

Get a list of all the keys held by this worker.
"""
function get_keys(worker::Worker, comm::TCPSocket, msg::Dict)
    return collect(keys(worker.data))
end


##############################     COMPUTE-STREAM FUNCTIONS    #############################

"""
    add_task(worker::Worker; kwargs...)

Add a task to the worker's list of tasks to be computed.

# Keywords

- `key::String`: The tasks's unique identifier. Throws an exception if blank.
- `priority::Array`: The priority of the task. Throws an exception if blank.
- `who_has::Dict`: Map of dependent keys and the addresses of the workers that have them.
- `nbytes::Dict`: Map of the number of bytes of the dependent key's data.
- `duration::String`: The estimated computation cost of the given key. Defaults to "0.5".
- `resource_restrictions::Dict`: Resources required by a task. Defeaults to an empty Dict.
- `func::Union{String, Array{UInt8,1}}`: The callable funtion for the task, serialized.
- `args::Union{String, Array{UInt8,1}}`: The arguments for the task, serialized.
- `kwargs::Union{String, Array{UInt8,1}}`: The keyword arguments for the task, serialized.
- `future::Union{String, Array{UInt8,1}}`: The tasks's serialized `DeferredFuture`.
"""
function add_task(
    worker::Worker;
    key::String="",
    priority::Array=[],
    who_has::Dict=Dict(),
    nbytes::Dict=Dict(),
    duration::String="0.5",
    resource_restrictions::Dict=Dict(),
    func::Union{String, Array{UInt8,1}}="",
    args::Union{String, Array{UInt8,1}}="",
    kwargs::Union{String, Array{UInt8,1}}="",
    future::Union{String, Array{UInt8,1}}="",
)
    if key == "" || priority == []
        throw(ArgumentError("Key or task priority cannot be empty"))
    end

    if !isempty(priority)
        priority = map(parse, priority)
        insert!(priority, 2, worker.priority_counter)
        priority = tuple(priority...)
    end

    if haskey(worker.tasks, key)
        state = worker.task_state[key]
        if state in ("memory", "error")
            if state == "memory"
                @assert key in worker.data
            end
            debug(logger, "Asked to compute pre-existing result: $key: $state")
            send_task_state_to_scheduler(worker, key)
            return
        end
        if state in IN_PLAY
            return
        end
    end

    if haskey(worker.dep_state, key) && worker.dep_state[key] == "memory"
        worker.task_state[key] = "memory"
        send_task_state_to_scheduler(worker, key)
        worker.tasks[key] = ()
        push!(worker.log, (key, "new-task-already-in-memory"))
        worker.priorities[key] = priority
        worker.durations[key] = parse(duration)
        return
    end

    push!(worker.log, (key, "new"))
    try
        start_time = time()
        worker.tasks[key] = deserialize_task(func, args, kwargs)
        debug(logger, "In add_task: $(worker.tasks[key])")
        stop_time = time()

        if stop_time - start_time > 0.010
            push!(worker.startstops[key], ("deserialize", start_time, stop_time))
        end
    catch exception
        error_msg = Dict(
            "exception" => "$(typeof(exception)))",
            "traceback" => sprint(showerror, exception),
            "key" => to_key(key),
            "op" => "task-erred",
        )
        warn(
            logger,
            "Could not deserialize task with key: \"$key\": $(error_msg["traceback"])"
        )
        send_msg(get(worker.batched_stream), error_msg)
        push!(worker.log, (key, "deserialize-error"))
        return
    end

    if !isempty(future)
        worker.futures[key] = to_deserialize(future)
    end

    worker.priorities[key] = priority
    worker.durations[key] = parse(duration)
    if !isempty(resource_restrictions)
        worker.resource_restrictions[key] = resource_restrictions
    end
    worker.task_state[key] = "waiting"

    if !isempty(nbytes)
        for (k,v) in nbytes
            worker.nbytes[k] = parse(v)
        end
    end

    worker.dependencies[key] = Set(keys(who_has))
    worker.waiting_for_data[key] = Set()

    for dep in keys(who_has)
        if !haskey(worker.dependents, dep)
            worker.dependents[dep] = Set()
        end
        push!(worker.dependents[dep], key)

        if !haskey(worker.dep_state, dep)
            if haskey(worker.task_state, dep) && worker.task_state[dep] == "memory"
                worker.dep_state[dep] = "memory"
            else
                worker.dep_state[dep] = "waiting"
            end
        end

        if worker.dep_state[dep] != "memory"
            push!(worker.waiting_for_data[key], dep)
        end
    end

    for (dep, workers) in who_has
        @assert !isempty(workers)
        if !haskey(worker.who_has, dep)
            worker.who_has[dep] = Set(workers)
        end
        push!(worker.who_has[dep], workers...)

        for worker_addr in workers
            push!(worker.has_what[worker_addr], dep)
            if worker.dep_state[dep] != "memory"
                push!(worker.pending_data_per_worker[worker_addr], dep)
            end
        end
    end

    if !isempty(worker.waiting_for_data[key])
        push!(worker.data_needed, key)
    else
        transition(worker, key, "ready")
    end

    if worker.validate && !isempty(who_has)
        @assert all(dep -> haskey(worker.dep_state, dep), keys(who_has))
        @assert all(dep -> haskey(worker.nbytes, dep), keys(who_has))
        for dep in keys(who_has)
            validate_dep(worker, dep)
        end
        validate_key(worker, key)
    end
end

"""
    release_key(worker::Worker; key::String="", cause=nothing, reason::String="")

Delete a key and its data.
"""
function release_key(worker::Worker; key::String="", cause=nothing, reason::String="")
    if key == "" || !haskey(worker.task_state, key)
        return
    end

    state = pop!(worker.task_state, key)
    if reason == "stolen" && state in ("executing", "memory")
        worker.task_state[key] = state
        return
    end

    if cause != nothing
        push!(worker.log, (key, "release-key", cause))
    else
        push!(worker.log, (key, "release-key"))
    end

    delete!(worker.tasks, key)
    if haskey(worker.data, key) && !haskey(worker.dep_state, key)
        delete!(worker.data, key)
        delete!(worker.nbytes, key)
        delete!(worker.types, key)
    end

    haskey(worker.waiting_for_data, key) && delete!(worker.waiting_for_data, key)

    for dep in pop!(worker.dependencies, key, ())
        delete!(worker.dependents[dep], key)
        if worker.dependents[dep] == nothing && worker.dep_state[dep] == "waiting"
            release_dep(worker, dep)
        end
    end

    delete!(worker.priorities, key)
    delete!(worker.durations, key)

    haskey(worker.exceptions, key) && delete!(worker.exceptions, key)
    haskey(worker.tracebacks, key) && delete!(worker.tracebacks, key)
    haskey(worker.startstops, key) && delete!(worker.startstops, key)

    if key in worker.executing
        delete!(worker.executing, key)
    end

    haskey(worker.resource_restrictions, key) && delete!(worker.resource_restrictions, key)

    if state in PROCESSING  # Task is not finished
        send_msg(
            get(worker.batched_stream),
            Dict("op" => "release", "key" => to_key(key), "cause" => cause)
        )
    end
end

"""
    release_dep(worker::Worker, dep::String)

Delete a dependency key and its data.
"""
function release_dep(worker::Worker, dep::String)
    if haskey(worker.dep_state, dep)
        push!(worker.log, (dep, "release-dep"))
        pop!(worker.dep_state, dep)

        if haskey(worker.suspicious_deps, dep)
            delete!(worker.suspicious_deps, dep)
        end

        if !haskey(worker.task_state, dep)
            if haskey(worker.data, dep)
                delete!(worker.data, dep)
                delete!(worker.types, dep)
            end
            delete!(worker.nbytes, dep)
        end

        haskey(worker.in_flight_tasks, dep) && delete!(worker.in_flight_tasks, dep)

        for key in pop!(worker.dependents, dep, ())
            delete!(worker.dependencies[key], dep)
            if worker.task_state[key] != "memory"
                release_key(worker, key, cause=dep)
            end
        end
    end
end

##############################       EXECUTING FUNCTIONS      ##############################

"""
    meets_resource_requirements(worker::Worker, key::String)

Ensure a task meets its resource requirements.
"""
function meets_resource_requirements(worker::Worker, key::String)
    if haskey(worker.resource_restrictions, key) == false
        return true
    end
    for (resource, needed) in worker.resource_restrictions[key]
        # TODO: remove since this appears to be unnecessary
        error(logger, "Used available resources")
        if worker.available_resources[resource] < needed
            return false
        end
    end

    return true
end

"""
    ensure_computing(worker::Worker)

Make sure the worker is computing available tasks.
"""
function ensure_computing(worker::Worker)
    while !isempty(worker.constrained)
        error(logger, "in ensure_computing: processing constrained")
        key = worker.constrained[1]
        if worker.task_state[key] != "constained"
            shift!(worker.constrained)
            continue
        end
        if meets_resource_requirements(worker, key)
            shift!(worker.constrained)
            @sync transition(worker, key, "executing")
        else
            break
        end
    end
    while !isempty(worker.ready)
        key = dequeue!(worker.ready)
        if worker.task_state[key] in READY
            @sync transition(worker, key, "executing")
        end
    end
end

"""
    execute(worker::Worker, key::String, report=false)

Execute the task identified by `key`. Reports results to scheduler if report=true.
"""
function execute(worker::Worker, key::String, report=false)
    @async begin
        if key ∉ worker.executing || !haskey(worker.task_state, key)
            return
        end
        if worker.validate
            @assert !haskey(worker.waiting_for_data, key)
            @assert worker.task_state[key] == "executing"
        end

        (func, args, kwargs) = worker.tasks[key]

        start_time = time()
        args2 = pack_data(args, worker.data, key_types=String)
        kwargs2 = pack_data(kwargs, worker.data, key_types=String)
        stop_time = time()

        if stop_time - start_time > 0.005
            # TODO: is startstops needed?
            push!(worker.startstops[key], ("disk-read", start_time, stop_time))
        end

        result = apply_function(func, args2, kwargs2)

        if worker.task_state[key] != "executing"
            return
        end

        result["key"] = key
        value = pop!(result, "result", nothing)

        push!(worker.startstops[key], ("compute", result["start"], result["stop"]))

        if result["op"] == "task-finished"
            !isready(worker.futures[key]) && put!(worker.futures[key], value)
            worker.nbytes[key] = result["nbytes"]
            worker.types[key] = result["type"]
            transition(worker, key, "memory", value=value)
        else
            !isready(worker.futures[key]) && put!(worker.futures[key], result["exception"])
            worker.exceptions[key] = result["exception"]
            worker.tracebacks[key] = result["traceback"]
            warn(
                logger,
                "Compute Failed:\n" *
                "Function:  $func\n" *
                "args:      $args2\n" *
                "kwargs:    $kwargs2\n" *
                "Exception: $(result["exception"])\n" *
                "Traceback: $(result["traceback"])"
            )
            transition(worker, key, "error")
        end

        debug(logger, "Send compute response to scheduler: ($key: $value), $result")

        if worker.validate
            @assert key ∉ worker.executing
            @assert !haskey(worker.waiting_for_data, key)
        end

        ensure_computing(worker)
        ensure_communicating(worker)

        if key in worker.executing
            delete!(worker.executing, key)
        end
    end
end

"""
    put_key_in_memory(worker::Worker, key::String, value; should_transition::Bool=true)

Store the result (`value`) of the task identified by `key`.
"""
function put_key_in_memory(worker::Worker, key::String, value; should_transition::Bool=true)
    if !haskey(worker.data, key)
        worker.data[key] = value

        if !haskey(worker.nbytes, key)
            worker.nbytes[key] = sizeof(value)
        end

        worker.types[key] = typeof(value)

        for dep in get(worker.dependents, key, [])
            if haskey(worker.waiting_for_data, dep)
                if key in worker.waiting_for_data[dep]
                    delete!(worker.waiting_for_data[dep], key)
                end
                if isempty(worker.waiting_for_data[dep])
                    transition(worker, dep, "ready")
                end
            end
        end

        if should_transition && haskey(worker.task_state, key)
            transition(worker, key, "memory")
        end

        push!(worker.log, (key, "put-in-memory"))
    end
end

##############################  PEER DATA GATHERING FUNCTIONS ##############################

"""
    ensure_communicating(worker::Worker)

Ensure the worker is communicating with its peers to gather dependencies as needed.
"""
function ensure_communicating(worker::Worker)
    changed = true
    while (
        changed &&
        !isempty(worker.data_needed) &&
        length(worker.in_flight_workers) < worker.total_connections
    )
        changed = false
        debug(
            logger,
            "Ensure communicating.  " *
            "Pending: $(length(worker.data_needed)).  " *
            "Connections: $(length(worker.in_flight_workers))/$(worker.total_connections)"
        )

        key = front(worker.data_needed)

        if !haskey(worker.tasks, key)
            shift!(worker.data_needed)
            changed = true
            continue
        end

        if !haskey(worker.task_state, key) || worker.task_state[key] != "waiting"
            push!(worker.log, (key, "communication pass"))
            shift!(worker.data_needed)
            changed = true
            continue
        end

        deps = worker.dependencies[key]
        if worker.validate
            @assert all(dep -> haskey(worker.dep_state, dep), deps)
        end

        deps = collect(filter(dep -> (worker.dep_state[dep] == "waiting"), deps))

        missing_deps = Set(filter(dep -> !haskey(worker.who_has, dep), deps))
        if !isempty(missing_deps)
            info(logger, "Can't find dependencies for key $key")
            missing_deps2 = Set(filter(dep -> dep ∉ worker.missing_dep_flight, missing_deps))

            for dep in missing_deps2
                push!(worker.missing_dep_flight, dep)
            end

            @sync handle_missing_dep(worker, missing_deps2)

            deps = collect(filter(dep -> dep ∉ missing_deps, deps))
        end

        push!(worker.log, ("gather-dependencies", key, deps))
        in_flight = false

        while (
            !isempty(deps) && length(worker.in_flight_workers) < worker.total_connections
        )
            dep = pop!(deps)
            if worker.dep_state[dep] != "waiting" || !haskey(worker.who_has, dep)
                continue
            end

            workers = collect(
                filter(w -> !haskey(worker.in_flight_workers, w), worker.who_has[dep])
            )
            if isempty(workers)
                in_flight = true
                continue
            end
            worker_addr = rand(workers)
            to_gather = select_keys_for_gather(worker, worker_addr, dep)

            worker.in_flight_workers[worker_addr] = to_gather
            for dep in to_gather
                transition_dep(worker, dep, "flight", worker_addr=worker_addr)
            end
            @sync gather_dep(worker, worker_addr, dep, to_gather, cause=key)
            changed = true
        end

        if isempty(deps) && isempty(in_flight)
            shift!(worker.data_needed)
        end
    end
end

"""
    gather_dep(worker::Worker, worker_addr::String, dep::String, deps::Set; cause="")

Gather a dependency from `worker_addr`.
"""
function gather_dep(worker::Worker, worker_addr::String, dep::String, deps::Set; cause="")
    @async begin
        if worker.status != "running"
            return
        end

        response = Dict()
        try
            if worker.validate
                validate_state(worker)
            end

            push!(worker.log, ("request-dep", dep, worker_addr, deps))
            debug(logger, "Request $(length(deps)) keys")
            start_time = time()
            connection = Rpc(build_URI(worker_addr))
            response = send_recv(
                connection,
                Dict(
                    "op" => "get_data",
                    "keys" => [to_key(key) for key in deps],
                    "who" => address(worker),
                )
            )
            stop_time = time()

            close(connection)

            response = Dict(k => to_deserialize(v) for (k,v) in response)
            if cause != ""
                push!(worker.startstops[cause], ("transfer", start_time, stop_time))
            end

            push!(worker.log, ("receive-dep", worker, collect(keys(response))))

            if !isempty(response)
                send_msg(
                    get(worker.batched_stream),
                    Dict("op" => "add-keys", "keys" => collect(keys(response)))
                )
            end
        catch exception
            # EOFErrors are expected when connections are closed unexpectadly
            isa(exception, EOFError) || rethrow(exception)

            warn(logger, "Worker stream died during communication $worker_addr")
            push!(worker.log, ("received-dep-failed", worker_addr))

            for dep in pop!(worker.has_what, worker_addr)
                delete(worker.who_hash[dep], worker_addr)
                if haskey(worker.who_has, dep) && isempty(worker.who_has[dep])
                    delete!(worker.who_has, dep)
                end
            end
        end

        for dep in pop!(worker.in_flight_workers, worker_addr)
            if haskey(response, dep)
                transition_dep(worker, dep, "memory", value=response[dep])
            elseif !haskey(worker.dep_state, dep) || worker.dep_stat[d] != "memory"
                transition_dep(worker, dep, "waiting", worker_addr=worker_addr)
            end

            if !haskey(response, dep) && haskey(worker.dependents, dep)
                push!(worker.log, ("missing-dep", dep))
            end
        end

        if worker.validate
            validate_state(worker)
        end

        ensure_computing(worker)
        ensure_communicating(worker)
    end
end


"""
    handle_missing_dep(worker::Worker, deps::Set{String})

Handle a missing dependency that can't be found on any peers.
"""
function handle_missing_dep(worker::Worker, deps::Set{String})
    # TODO: test
    @async begin
        original_deps = deps
        push!(worker.log, ("handle-missing", deps))

        deps = Set(filter(dep -> haskey(worker.dependents, dep), deps))
        if isempty(deps)
            return
        end

        for dep in deps
            suspicious = worker.suspicious_deps[dep]
            if suspicious > 5
                delete!(deps, dep)
                bad_dep(worker, dep)
            end
        end
        if isempty(deps)
            return
        end

        for dep in deps
            info(
                logger,
                "Dependent not found: $dep $(worker.suspicious_deps[dep]) .  " *
                "Asking scheduler"
            )
        end

        who_has = send_recv(
            worker.scheduler,
            Dict("op" => "who_has", "keys" => [to_key(key) for key in deps])
        )
        who_has = Dict(k => v for (k,v) in filter((k,v) -> !isempty(v), who_has))
        update_who_has(worker, who_has)

        for dep in deps
            worker.suspicious_deps[dep] += 1

            if !haskey(who_has, dep)
                push!(
                    worker.log,
                    (dep, "no workers found", get(worker.dependents, dep, nothing)),
                )
                release_dep(worker, dep)
            else
                push!(worker.log, (dep, "new workers found"))
                for key in get(worker.dependents, dep, ())
                    if haskey(worker.waiting_for_data, key)
                        push!(worker.data_needed, key)
                    end
                end
            end
        end

        for dep in original_deps
            delete!(worker.missing_dep_flight, dep)
        end

        ensure_communicating(worker)
    end
end

"""
    handle_missing_dep(worker::Worker, deps::Set{String})

Handle a bad dependency.
"""
function bad_dep(worker::Worker, dep::String)
    for key in worker.dependents[dep]
        msg = "Could not find dependent $dep.  Check worker logs"
        worker.exceptions[key] = msg
        worker.tracebacks[key] = msg
        transition(worker, key, "error")
    end
    release_dep(worker, dep)
end

"""
    update_who_has(worker::Worker, who_has::Dict{String, String})

Ensure `who_has` is up to date and accurate.
"""
function update_who_has(worker::Worker, who_has::Dict{String, String})
    for (dep, workers) in who_has
        if !isempty(workers)
            continue
        end
        if haskey(worker.who_has, dep)
            push!(worker.who_has[dep], workers...)
        else
            worker.who_has[dep] = Set(workers)
        end

        for worker_address in workers
            push!(worker.has_what[worker], dep)
        end
    end
end

"""
    select_keys_for_gather(worker::Worker, worker_addr::String, dep::String)

Select which keys to gather from peer at `worker_addr`.
"""
function select_keys_for_gather(worker::Worker, worker_addr::String, dep::String)
    deps = Set([dep])

    total_bytes = worker.nbytes[dep]
    pending = worker.pending_data_per_worker[worker_addr]

    while !isempty(pending)
        dep = shift!(pending)
        if !haskey(worker.dep_state, dep) || worker.dep_state[dep] != "waiting"
            continue
        end
        if total_bytes + worker.nbytes[dep] > worker.target_message_size
            break
        end
        push!(deps, dep)
        total_bytes += worker.nbytes[dep]
    end

    return deps
end


##############################      TRANSITION FUNCTIONS      ##############################

"""
    transition(worker::Worker, key::String, finish_state::String; kwargs...)

Transition task with identifier `key` to finish_state from its current state.
"""
function transition(worker::Worker, key::String, finish_state::String; kwargs...)
    start_state = worker.task_state[key]
    notice(logger, "In transition: transitioning key $key from $start_state to $finish_state")

    if start_state == finish_state
        warn(logger, "Called `transition` with same start and end state")
        return
    end

    transition_func = worker.transitions[start_state, finish_state]
    new_state = transition_func(worker, key, ;kwargs...)

    worker.task_state[key] = new_state

end

function transition_waiting_ready(worker::Worker, key::String)
    if worker.validate
        @assert worker.task_state[key] == "waiting"
        @assert haskey(worker.waiting_for_data, key)
        @assert isempty(worker.waiting_for_data[key])
        @assert all(dep -> haskey(worker.data, dep), worker.dependencies[key])
        @assert key ∉ worker.executing
        @assert !haskey(worker.ready, key)
    end

    delete!(worker.waiting_for_data, key)
    if haskey(worker.resource_restrictions, key)
        push!(worker.constrained, key)
        return "constrained"
    else
        enqueue!(worker.ready, key, worker.priorities[key])
        return "ready"
    end
end

function transition_waiting_memory(worker::Worker, key::String, value::Any=nothing)
    if worker.validate
        @assert worker.task_state[key] == "waiting"
        @assert key in worker.waiting_for_data
        @assert key ∉ worker.executing
        @assert !haskey(worker.ready, key)
    end

    delete!(worker.waiting_for_data, key)
    send_task_state_to_scheduler(worker, key)
    return "memory"
end

function transition_ready_executing(worker::Worker, key::String)
    if worker.validate
        @assert !haskey(worker.waiting_for_data, key)
        @assert worker.task_state[key] in READY
        @assert !haskey(worker.ready, key)
        @assert all(dep -> haskey(worker.data, dep), worker.dependencies[key])
    end

    push!(worker.executing, key)
    execute(worker, key)
    return "executing"
end

function transition_ready_memory(worker::Worker, key::String, value::Any=nothing)
    send_task_state_to_scheduler(worker, key)
    return "memory"
end

function transition_constrained_executing(worker::Worker, key::String)
    transition_ready_executing(worker, key)
    for (resource, quantity) in worker.resource_restrictions[key]
        worker.available_resources[resource] -= quantity
    end

    if worker.validate
        @assert all(v >= 0 for v in values(worker.available_resources))
    end
    return "executing"
end

function transition_executing_done(worker::Worker, key::String; value::Any=no_value)
    if worker.validate
        @assert key in worker.executing || key in worker.long_running
        @assert !haskey(worker.waiting_for_data, key)
        @assert !haskey(worker.ready, key)
    end

    if haskey(worker.resource_restrictions, key)
        for (resource, quantity) in worker.resource_restrictions[key]
            worker.available_resources[resource] += quantity
        end
    end

    if worker.task_state[key] == "executing"
        delete!(worker.executing, key)
        worker.executed_count += 1
    end

    if value != no_value
        put_key_in_memory(worker, key, value, should_transition=false)
        if haskey(worker.dep_state, key)
            transition_dep(worker, key, "memory")
        end
    end

    if !isnull(worker.batched_stream)
        send_task_state_to_scheduler(worker, key)
    else
        error("Connection closed in transition_executing_done")
    end

    return "memory"
end

"""
    transition_dep(worker::Worker, dep::String, finish_state::String; kwargs...)

Transition dependency task with identifier `key` to finish_state from its current state.
"""
function transition_dep(worker::Worker, dep::String, finish_state::String; kwargs...)
    if haskey(worker.dep_state, dep)
        start_state = worker.dep_state[dep]

        if start_state != finish_state
            func = worker.dep_transitions[(start_state, finish_state)]
            func(worker, dep, ;kwargs...)
            push!(worker.log, ("dep", dep, start_state, finish_state))

            if haskey(worker.dep_state, dep)
                worker.dep_state[dep] = finish_state
                if worker.validate
                    validate_dep(worker, dep)
                end
            end
        end
    end
end

function transition_dep_waiting_flight(worker::Worker, dep::String; worker_addr::String="")
    if worker.validate
        @assert worker_addr != ""
        @assert !haskey(worker.in_flight_tasks, dep)
        @assert !isempty(worker.dependents[dep])
    end

    worker.in_flight_tasks[dep] = worker_addr
end

function transition_dep_flight_waiting(worker::Worker, dep::String; worker_addr::String="")
    if worker.validate
        @assert worker_addr != ""
        @assert haskey(worker.in_flight_tasks, dep)
    end

    delete!(worker.in_flight_tasks, dep)

    haskey(worker.who_has, dep) && delete!(worker.who_has[dep], worker_addr)
    haskey(worker.has_what, worker_addr) && delete!(worker.has_what[worker_addr], dep)

    if !haskey(worker.who_has, dep) || isempty(worker.who_has[dep])
        if dep ∉ worker.missing_dep_flight
            push!(worker.missing_dep_flight, dep)
            handle_missing_dep(worker, Set(dep))
        end
    end

    for key in get(worker.dependents, dep, ())
        if worker.task_state[key] == "waiting"
            unshift!(worker.data_needed, key)
        end
    end

    if isempty(worker.dependents[dep])
        release_dep(worker, dep)
    end
end

function transition_dep_flight_memory(worker::Worker, dep::String; value=nothing)
    if worker.validate
        @assert haskey(worker.in_flight_tasks, dep)
    end

    delete!(worker.in_flight_tasks, dep)
    worker.dep_state[dep] = "memory"
    put_key_in_memory(worker, dep, value)
end


function transition_dep_waiting_memory(worker::Worker, dep::String; value=nothing)
    if worker.validate
        @assert haskey(worker.data, dep)
        @assert haskey(worker.nbytes, dep)
        @assert haskey(worker.types, dep)
        @assert worker.task_state[dep] == "memory"
    end
end


##############################      VALIDATION FUNCTIONS      ##############################

"""
    validate_key(worker::Worker, key::String)

Validate task with identifier `key`.
"""
function validate_key(worker::Worker, key::String)
    state = worker.task_state[key]
    if state == "memory"
        validate_key_memory(worker, key)
    elseif state == "waiting"
        validate_key_waiting(worker, key)
    elseif state == "ready"
        validate_key_ready(worker, key)
    elseif state == "executing"
        validate_key_executing(worker, key)
   end
end

function validate_key_memory(worker::Worker, key::String)
    @assert haskey(worker.data, key)
    @assert haskey(worker.nbytes, key)
    @assert !haskey(worker.waiting_for_data, key)
    @assert key ∉ worker.executing
    @assert !haskey(worker.ready, key)
    if haskey(worker.dep_state, key)
        @assert worker.dep_state[key] == "memory"
    end
end

function validate_key_executing(worker::Worker, key::String)
    @assert key in worker.executing
    @assert !haskey(worker.data, key)
    @assert !haskey(worker.waiting_for_data, key)
    @assert all(dep in worker.data for dep in worker.dependencies[key])
end

function validate_key_ready(worker::Worker, key::String)
    @assert key in peek(worker.ready)
    @assert !haskey(worker.data, key)
    @assert key ∉ worker.executing
    @assert !haskey(worker.waiting_for_data, key)
    @assert all(dep -> haskey(worker.data, dep), worker.dependencies[key])
end

function validate_key_waiting(worker::Worker, key::String)
    @assert !haskey(worker.data, key)
    @assert any(dep -> !haskey(worker.data, dep), worker.dependencies[key])
end

"""
    validate_dep(worker::Worker, dep::String)

Validate task dependency with identifier `key`.
"""
function validate_dep(worker::Worker, dep::String)
    state = worker.dep_state[dep]
    if state == "waiting"
        validate_dep_waiting(worker, dep)
    elseif state == "flight"
        validate_dep_flight(worker, dep)
    elseif state == "memory"
        validate_dep_memory(worker, dep)
    else
        error("Unknown dependent state: $state")
    end
end

function validate_dep_waiting(worker::Worker, dep::String)
    @assert !haskey(worker.data, dep)
    @assert haskey(worker.nbytes, dep)
    @assert !isempty(worker.dependents[dep])
    @assert !any(key -> haskey(worker.ready, key), worker.dependents[dep])
end

function validate_dep_flight(worker::Worker, dep::String)
    @assert !haskey(worker.data, dep)
    @assert haskey(worker.nbytes, dep)
    @assert !any(key -> haskey(worker.ready, key), worker.dependents[dep])
    peer = worker.in_flight_tasks[dep]
    @assert dep in worker.in_flight_workers[peer]
end

function validate_dep_memory(worker::Worker, dep::String)
    @assert haskey(worker.data, dep)
    @assert haskey(worker.nbytes, dep)
    @assert haskey(worker.types, dep)
    if haskey(worker.task_state, dep)
       @assert worker.task_state[dep] == "memory"
    end
end

"""
    validate_state(worker::Worker)

Validate current worker state.
"""
function validate_state(worker::Worker)
    if worker.status != "running"
       return
   end
    for (key, workers) in worker.who_has
        for worker_addr in workers
            @assert key in worker.has_what[worker_addr]
        end
    end

    for (worker_addr, keys) in worker.has_what
        for key in keys
            @assert worker_addr in worker.who_has[key]
        end
    end

    for key in keys(worker.task_state)
        validate_key(worker, key)
    end

    for dep in keys(worker.dep_state)
        validate_dep(worker, dep)
    end

    for (key, deps) in worker.waiting_for_data
        if key ∉ worker.data_needed
            for dep in deps
                @assert (
                    haskey(worker.in_flight_tasks, dep) ||
                    haskey(worker.missing_dep_flight, dep) ||
                    issubset(worker.who_has[dep], worker.in_flight_workers)
                )
            end
        end
    end

    for key in keys(worker.tasks)
        if worker.task_state[key] == "memory"
            @assert isa(worker.nbytes[key], Integer)
            @assert !haskey(worker.waiting_for_data, key)
            @assert haskey(worker.data, key)
        end
    end
end

##############################      SCHEDULER FUNCTIONS       ##############################

"""
    send_task_state_to_scheduler(worker::Worker, key::String)

Send the state of task `key` to the scheduler.
"""
function send_task_state_to_scheduler(worker::Worker, key::String)
    if haskey(worker.data, key)
        nbytes = get(worker.nbytes, key, sizeof(worker.data[key]))
        data_type = get(worker.types, key, typeof(worker.data[key]))

        msg = Dict{String, Any}(
            "op" => "task-finished",
            "status" => "OK",
            "key" => to_key(key),
            "nbytes" => nbytes,
            "type" => string(data_type)
        )
    elseif haskey(worker.exceptions, key)
        msg = Dict{String, Any}(
            "op" => "task-erred",
            "status" => "error",
            "key" => to_key(key),
            "exception" => worker.exceptions[key],
            "traceback" => worker.tracebacks[key],
        )
    else
        error(logger, "Key not ready to send to worker, $key: $(worker.task_state[key])")
        return
    end

    if haskey(worker.startstops, key)
        msg["startstops"] = worker.startstops[key]
    end

    send_msg(get(worker.batched_stream), msg)
end

##############################         OTHER FUNCTIONS        ##############################

"""
    deserialize_task(func, args, kwargs) -> Tuple

Deserialize task inputs and regularize to func, args, kwargs.

# Returns
- `Tuple`: The deserialized function, arguments and keyword arguments for the task.
"""
function deserialize_task(
    func::Union{String, Array},
    args::Union{String, Array},
    kwargs::Union{String, Array}
)
    !isempty(func) && (func = to_deserialize(func))
    !isempty(args) && (args = to_deserialize(args))
    !isempty(kwargs) && (kwargs = to_deserialize(kwargs))

    return (func, args, kwargs)
end

"""
    apply_function(func, args, kwargs) -> Dict()

Run a function and return collected information.
"""
function apply_function(func, args, kwargs)
    start_time = time()
    result_msg = Dict{String, Any}()
    try
        func = eval(func)
        result = func(args..., kwargs...)
        result_msg["op"] = "task-finished"
        result_msg["status"] = "OK"
        result_msg["result"] = result
        result_msg["nbytes"] = sizeof(result)
        result_msg["type"] = typeof(result)
    catch exception
        result_msg = Dict{String, Any}(
            "exception" => "$(typeof(exception))",
            "traceback" => sprint(showerror, exception),
            "op" => "task-erred"
        )
    end
    stop_time = time()
    result_msg["start"] = start_time
    result_msg["stop"] = stop_time
    return result_msg
end
