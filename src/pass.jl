# Helper extensions.
Base.iterate(compact::CC.IncrementalCompact, state = nothing) =
   CC.iterate(compact, state)
Base.getindex(compact::CC.IncrementalCompact, idx) = CC.getindex(compact, idx)

Base.iterate(useref::CC.UseRefIterator, state...) = CC.iterate(useref, state...)
Base.getindex(useref::CC.UseRef) = CC.getindex(useref)

function refcount_pass!(ir::CC.IRCode)
    # For an IRCode, find `RefCounted` statements and record their
    # definitions and uses in that IR.
    ir, defuses = find_rcs!(ir)

    if !isempty(defuses)
        Core.println("Found following defuses:")
        for (i, defuse) in enumerate(defuses)
            Core.println(" - [$i] $defuse")
        end
    end

    # Given a CFG and defuses for it, determine exits, i.e.:
    # places, where `def` liveness ends or it escapes into another function.
    exits = determine_exits!(ir.cfg, defuses)

    ir = rc_insertion!(ir, defuses, exits)
    return ir
end

"""
Returns:

- `is_incrementing::Bool`:
    `true` if `stmt`'s kind does not prevent incrementing the counter
    and we should increment it.
    `Core.getfield` and `Core.finalizer` prevent incrementing.

- `is_new_ref::Bool`:
    `true` if `stmt` is an access to an object's field or memory reference.
"""
function stmt_kind(stmt, compact)
    is_incrementing = true
    is_new_ref = false

    if stmt isa Expr
        if CC.is_known_call(stmt, Core.finalizer, compact)
            is_incrementing = false
        elseif CC.is_known_call(stmt, Core.getfield, compact)
            is_incrementing = false
            is_new_ref = true
        elseif CC.is_known_call(stmt, Core.setfield!, compact)
        elseif CC.is_known_call(stmt, Core.memoryrefget, compact)
            is_new_ref = true
        end
        # TODO gc preserve begin/end
    elseif stmt isa GlobalRef
        is_new_ref = true
    elseif stmt isa CC.PhiCNode
        is_new_ref = true
    end

    return (; is_incrementing, is_new_ref)
end

function find_rcs!(ir::CC.IRCode)::Tuple{CC.IRCode, Vector{DefUse}}
    defuses = Dict{Union{CC.SSAValue, CC.Argument}, DefUse}()

    # Find `RefCounted` argtypes and mark them as `defs` for `defuses`.
    for (i, T) in enumerate(ir.argtypes)
        wT = CC.widenconst(T)
        is_rctype(wT) || continue
        Core.println("Argument $i: $T (widened $wT, is_rctype $(is_rctype(wT)))")

        defuses[CC.Argument(i)] = DefUse(CC.Argument(i), [1], Int[])
    end

    compact = CC.IncrementalCompact(ir)
    for ((old_idx, idx), stmt) in compact
        inst::CC.Instruction = compact[CC.SSAValue(idx)]

        (; is_incrementing, is_new_ref) = stmt_kind(stmt, compact)

        # Check if `inst` is a call to `RefCounted` ctor
        # or the return value of some function is `RefCounted`.
        # Example:
        #  - `y = RefCounted(:y)`.
        #  - `y = some_func()::RefCounted`.
        is_rc = is_rctype(CC.widenconst(inst[:type]))
        is_ϕ = stmt isa CC.PhiNode

        # If ϕ stmt returns a `RefCounted` it also starts a new chain.
        # Process each of its edges.
        if is_rc && is_ϕ
            @assert false
        # If `stmt` is not `RefCounted` or not a `CC.PhiNode`,
        # record all `uses` of it.
        else
            # For every argument to `stmt`, record this `stmt` as its `use`
            # if it is a `RefCounted` obj (has entry in `defuses` already).
            for use_ref in CC.userefs(stmt)
                use = use_ref[]
                (use isa CC.SSAValue) || (use isa CC.Argument) || continue

                # Get defuses for `use`.
                # If it is `nothing`, then it is not a `RefCounted` obj
                # and we don't need to handle it.
                defuse = get(defuses, use, nothing)
                defuse ≡ nothing && continue
                push!(defuse.uses, idx)

                # TODO `is_gc_preserve`
                # TODO `arcuse` & `attach_arcscan`

                # Increment `RefCounted` counter on every use.
                if is_incrementing
                    Core.println("""Inserting increment:
                        - stmt: $stmt
                        - is_rc: $is_rc
                        - use: $use ($(typeof(use)))
                    """)
                    insert_increment!(
                        CC.InsertBefore(compact, CC.SSAValue(idx)),
                        inst[:line], use)
                end
            end
        end

        # If so, then it is considered as another `def`.
        if is_rc
            @assert !is_ϕ
            # TODO `is_additional_def`
            @assert !CC.isexpr(stmt, :(=))
            @assert !CC.is_known_call(stmt, setfield!, compact)

            val = CC.SSAValue(idx)
            defuse = get!(() -> DefUse(val, Int[], Int[]), defuses, val)
            push!(defuse.defs, idx)

            if is_new_ref
                insert_increment!(
                    CC.InsertHere(compact), inst[:line], CC.SSAValue(idx))
            end
            Core.println("returns `RefCounted`: stmt=$stmt, val=$val, is_new_ref=$is_new_ref")
        end
    end

    CC.non_dce_finish!(compact)
    CC.simple_dce!(compact)
    ir = CC.complete(compact)

    return ir, unique(values(defuses))
end

function determine_exits!(cfg::CC.CFG, defuses::Vector{DefUse})
    all_exits = Vector{Tuple{
        Union{CC.SSAValue, CC.Argument}, # Value for which exits are determined.
        Vector{Int},                     # Unconditional exits.
        Vector{Pair{Int, Int}}           # Conditional exits.
    }}()

    for defuse in defuses
        live_ins::CC.BlockLiveness = CC.compute_live_ins(
            cfg, sort(defuse.defs), defuse.uses)

        bbs = copy(live_ins.def_bbs)
        isempty(live_ins.live_in_bbs) || append!(bbs, live_ins.live_in_bbs)

        exits = Int[]
        conditional_exits = Pair{Int, Int}[]

        for bb in bbs
            # For each `bb` take its successor BBs
            # and count how many of them are in `bbs`.
            succs = cfg.blocks[bb].succs
            live_succs = count(bb -> bb ∈ bbs, succs)

            # If no successors, then this is an unconditional exit.
            if live_succs == 0
                push!(exits, bb)
                continue
            end

            # If all successors are in `bbs`, then it is not exit and move
            # to the next `bb`.
            live_succs == length(succs) && continue

            # Otherwise, other successor blocks are not in `bbs`,
            # then this is a conditional exit.
            for other_bb in succs
                other_bb ∈ bbs & continue
                push!(conditional_exits, bb => other_bb)
            end
        end
        push!(all_exits, (defuse.def, exits, conditional_exits))
        Core.println("Exits for $(defuse.def): $exits")
    end

    return all_exits
end

function rc_insertion!(
    ir::CC.IRCode, defuses::Vector{DefUse},
    all_exits::Vector{Tuple{
        Union{CC.SSAValue, CC.Argument}, # First def.
        Vector{Int}, # Unconditional exits.
        Vector{Pair{Int, Int}}, # Conditional exits.
    }}
)
    blocks = ir.cfg.blocks

    for (def, exits, cond_exits) in all_exits
        # Insert decrements for unconditional exits.
        for bb in exits
            terminator = last(blocks[bb].stmts)
            inst = ir.stmts[terminator]
            Core.println("""Inserting decrement:
                - stmt: $(inst[:stmt])
                - line $(inst[:line])
                - def: $def
                - terminator: $terminator
            """)
            insert_decrement!(
                CC.InsertBefore(ir, CC.SSAValue(terminator)),
                inst[:line], def)
        end

        # TODO cond_exits
    end
    return CC.compact!(ir)
end
