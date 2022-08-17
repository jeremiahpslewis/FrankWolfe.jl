
"""
    blended_pairwise_conditional_gradient(f, grad!, lmo, x0; kwargs...)

Implements the BPCG algorithm from [Tsuji, Tanaka, Pokutta](https://arxiv.org/abs/2110.12650).
The method uses an active set of current vertices.
Unlike away-step, it transfers weight from an away vertex to another vertex of the active set.
"""
function blended_pairwise_conditional_gradient(
    f,
    grad!,
    lmo,
    x0;
    line_search::LineSearchMethod=Adaptive(),
    epsilon=1e-7,
    max_iteration=10000,
    print_iter=1000,
    trajectory=false,
    verbose=false,
    memory_mode::MemoryEmphasis=InplaceEmphasis(),
    gradient=nothing,
    callback=nothing,
    traj_data=[],
    timeout=Inf,
    renorm_interval=1000,
    lazy=false,
    linesearch_workspace=nothing,
    lazy_tolerance=2.0,
    extra_vertex_storage=nothing,
    add_dropped_vertices=false,
    use_extra_vertex_storage=false,
    recompute_last_vertex=true,
)
    # add the first vertex to active set from initialization
    active_set = ActiveSet([(1.0, x0)])

    return blended_pairwise_conditional_gradient(
        f,
        grad!,
        lmo,
        active_set,
        line_search=line_search,
        epsilon=epsilon,
        max_iteration=max_iteration,
        print_iter=print_iter,
        trajectory=trajectory,
        verbose=verbose,
        memory_mode=memory_mode,
        gradient=gradient,
        callback=callback,
        traj_data=traj_data,
        timeout=timeout,
        renorm_interval=renorm_interval,
        lazy=lazy,
        linesearch_workspace=linesearch_workspace,
        lazy_tolerance=lazy_tolerance,
        extra_vertex_storage=extra_vertex_storage,
        add_dropped_vertices=add_dropped_vertices,
        use_extra_vertex_storage=use_extra_vertex_storage,
        recompute_last_vertex=recompute_last_vertex,
    )
end

"""
    blended_pairwise_conditional_gradient(f, grad!, lmo, active_set::ActiveSet; kwargs...)

Warm-starts BPCG with a pre-defined `active_set`.
"""
function blended_pairwise_conditional_gradient(
    f,
    grad!,
    lmo,
    active_set::ActiveSet;
    line_search::LineSearchMethod=Adaptive(),
    epsilon=1e-7,
    max_iteration=10000,
    print_iter=1000,
    trajectory=false,
    verbose=false,
    memory_mode::MemoryEmphasis=InplaceEmphasis(),
    gradient=nothing,
    callback=nothing,
    traj_data=[],
    timeout=Inf,
    renorm_interval=1000,
    lazy=false,
    linesearch_workspace=nothing,
    lazy_tolerance=2.0,
    extra_vertex_storage=nothing,
    add_dropped_vertices=false,
    use_extra_vertex_storage=false,
    recompute_last_vertex=true,
)

    # format string for output of the algorithm
    format_string = "%6s %13s %14e %14e %14e %14e %14e %14i\n"
    headers = ("Type", "Iteration", "Primal", "Dual", "Dual Gap", "Time", "It/sec", "#ActiveSet")
    function format_state(state, active_set)
        rep = (
            st[Symbol(state.tt)],
            string(state.t),
            Float64(state.primal),
            Float64(state.primal - state.dual_gap),
            Float64(state.dual_gap),
            state.time,
            state.t / state.time,
            length(active_set),
        )
        return rep
    end

    if trajectory
        callback = make_trajectory_callback(callback, traj_data)
    end

    if verbose
        callback = make_print_callback(callback, print_iter, headers, format_string, format_state)
    end

    t = 0
    x = get_active_set_iterate(active_set)
    primal = convert(eltype(x), Inf)
    tt = regular
    time_start = time_ns()

    d = similar(x)

    if verbose
        println("\nBlended Pairwise Conditional Gradient Algorithm.")
        NumType = eltype(x)
        println(
            "MEMORY_MODE: $memory_mode STEPSIZE: $line_search EPSILON: $epsilon MAXITERATION: $max_iteration TYPE: $NumType",
        )
        grad_type = typeof(gradient)
        println("GRADIENTTYPE: $grad_type LAZY: $lazy lazy_tolerance: $lazy_tolerance")
        if memory_mode isa InplaceEmphasis
            @info("In memory_mode memory iterates are written back into x0!")
        end
        if use_extra_vertex_storage && !lazy
            @info("vertex storage only used in lazy mode")
        end
        if (use_extra_vertex_storage || add_dropped_vertices) && extra_vertex_storage === nothing
            @warn(
                "use_extra_vertex_storage and add_dropped_vertices options are only usable with a extra_vertex_storage storage"
            )
        end
    end

    # likely not needed anymore as now the iterates are provided directly via the active set
    if gradient === nothing
        gradient = similar(x)
    end

    grad!(gradient, x)
    v = compute_extreme_point(lmo, gradient)
    # if !lazy, phi is maintained as the global dual gap
    phi = max(0, fast_dot(x, gradient) - fast_dot(v, gradient))
    local_gap = zero(phi)
    gamma = one(phi)

    if linesearch_workspace === nothing
        linesearch_workspace = build_linesearch_workspace(line_search, x, gradient)
    end

    if extra_vertex_storage === nothing
        use_extra_vertex_storage = add_dropped_vertices = false
    end

    while t <= max_iteration && phi >= max(epsilon, eps(epsilon))

        # managing time limit
        time_at_loop = time_ns()
        if t == 0
            time_start = time_at_loop
        end
        # time is measured at beginning of loop for consistency throughout all algorithms
        tot_time = (time_at_loop - time_start) / 1e9

        if timeout < Inf
            if tot_time ≥ timeout
                if verbose
                    @info "Time limit reached"
                end
                break
            end
        end

        #####################
        t += 1

        # compute current iterate from active set
        x = get_active_set_iterate(active_set)
        primal = f(x)
        if t > 1
            grad!(gradient, x)
        end

        _, v_local, v_local_loc, _, a_lambda, a, a_loc, _, _ =
            active_set_argminmax(active_set, gradient)

        dot_forward_vertex = fast_dot(gradient, v_local)
        dot_away_vertex = fast_dot(gradient, a)
        local_gap = dot_away_vertex - dot_forward_vertex
        if !lazy
            if t > 1
                v = compute_extreme_point(lmo, gradient)
                dual_gap = fast_dot(gradient, x) - fast_dot(gradient, v)
                phi = dual_gap
            end
        end
        # minor modification from original paper for improved sparsity
        # (proof follows with minor modification when estimating the step)
        if local_gap ≥ phi / lazy_tolerance
            d = muladd_memory_mode(memory_mode, d, a, v_local)
            vertex_taken = v_local
            gamma_max = a_lambda
            gamma = perform_line_search(
                line_search,
                t,
                f,
                grad!,
                gradient,
                x,
                d,
                gamma_max,
                linesearch_workspace,
                memory_mode,
            )
            gamma = min(gamma_max, gamma)
            tt = gamma ≈ gamma_max ? drop : pairwise
            if callback !== nothing
                state = CallbackState(
                    t,
                    primal,
                    primal - phi,
                    phi,
                    tot_time,
                    x,
                    vertex_taken,
                    gamma,
                    f,
                    grad!,
                    lmo,
                    gradient,
                    tt,
                )
                if callback(state, active_set) === false
                    break
                end
            end
            # reached maximum of lambda -> dropping away vertex
            if gamma ≈ gamma_max
                active_set.weights[v_local_loc] += gamma
                deleteat!(active_set, a_loc)
                if add_dropped_vertices
                    push!(extra_vertex_storage, a)
                end
            else # transfer weight from away to local FW
                active_set.weights[a_loc] -= gamma
                active_set.weights[v_local_loc] += gamma
                @assert active_set_validate(active_set)
            end
            active_set_update_iterate_pairwise!(active_set.x, gamma, v_local, a)
        else # add to active set
            if lazy # otherwise, v computed above already
                # optionally try to use the storage
                if use_extra_vertex_storage
                    lazy_threshold = dot_away_vertex - phi / lazy_tolerance
                    (found_better_vertex, new_forward_vertex) =
                        storage_find_argmin_vertex(extra_vertex_storage, gradient, lazy_threshold)
                    if found_better_vertex
                        if verbose
                            @debug("Found acceptable lazy vertex in storage")
                        end
                        v = new_forward_vertex
                        tt = lazy
                    else
                        v = compute_extreme_point(lmo, gradient)
                        tt = regular
                    end
                else
                    if t > 1
                        v = compute_extreme_point(lmo, gradient)
                    end
                    tt = regular
                end
            end
            vertex_taken = v
            dual_gap = fast_dot(gradient, x) - fast_dot(gradient, v)
            if (!lazy || dual_gap ≥ phi / lazy_tolerance)
                tt = regular
                d = muladd_memory_mode(memory_mode, d, x, v)

                gamma = perform_line_search(
                    line_search,
                    t,
                    f,
                    grad!,
                    gradient,
                    x,
                    d,
                    one(eltype(x)),
                    linesearch_workspace,
                    memory_mode,
                )

                if callback !== nothing
                    state = CallbackState(
                        t,
                        primal,
                        primal - phi,
                        phi,
                        tot_time,
                        x,
                        vertex_taken,
                        gamma,
                        f,
                        grad!,
                        lmo,
                        gradient,
                        tt,
                    )
                    if callback(state, active_set) === false
                        break
                    end
                end

                # dropping active set and restarting from singleton
                if gamma ≈ 1.0
                    if add_dropped_vertices
                        for vtx in active_set.atoms
                            if vtx != v
                                push!(extra_vertex_storage, vtx)
                            end
                        end
                    end
                    active_set_initialize!(active_set, v)
                else
                    renorm = mod(t, renorm_interval) == 0
                    active_set_update!(active_set, gamma, v, renorm, nothing)
                end
            else # dual step
                tt = dualstep
                # set to computed dual_gap for consistency between the lazy and non-lazy run.
                # that is ok as we scale with the K = 2.0 default anyways
                phi = dual_gap
                if callback !== nothing
                    state = CallbackState(
                        t,
                        primal,
                        primal - phi,
                        phi,
                        tot_time,
                        x,
                        vertex_taken,
                        gamma,
                        f,
                        grad!,
                        lmo,
                        gradient,
                        tt,
                    )
                    if callback(state, active_set) === false
                        break
                    end
                end    
            end
        end
        if (
            ((mod(t, print_iter) == 0 || tt == dualstep) == 0 && verbose) ||
            callback !== nothing ||
            !(line_search isa Agnostic || line_search isa Nonconvex || line_search isa FixedStep)
        )
            primal = f(x)
        end
    end

    # recompute everything once more for final verfication / do not record to trajectory though for now!
    # this is important as some variants do not recompute f(x) and the dual_gap regularly but only when reporting
    # hence the final computation.
    # do also cleanup of active_set due to many operations on the same set

    if verbose
        x = get_active_set_iterate(active_set)
        grad!(gradient, x)
        v = compute_extreme_point(lmo, gradient)
        primal = f(x)
        phi = fast_dot(x, gradient) - fast_dot(v, gradient)
        tt = last
        tot_time = (time_ns() - time_start) / 1e9
        if callback !== nothing
            state = CallbackState(
                t,
                primal,
                primal - phi,
                phi,
                tot_time,
                x,
                v,
                gamma,
                f,
                grad!,
                lmo,
                gradient,
                tt,
            )
            callback(state, active_set)
        end
    end
    active_set_renormalize!(active_set)
    active_set_cleanup!(active_set)
    x = get_active_set_iterate(active_set)
    grad!(gradient, x)
    # otherwise values are maintained to last iteration
    if recompute_last_vertex
        v = compute_extreme_point(lmo, gradient)
        primal = f(x)
        dual_gap = fast_dot(x, gradient) - fast_dot(v, gradient)
    end
    tt = pp
    tot_time = (time_ns() - time_start) / 1e9
    if callback !== nothing
        state = CallbackState(
            t,
            primal,
            primal - dual_gap,
            phi,
            tot_time,
            x,
            v,
            gamma,
            f,
            grad!,
            lmo,
            gradient,
            tt,
        )
        callback(state, active_set)
    end

    return x, v, primal, dual_gap, traj_data, active_set
end
