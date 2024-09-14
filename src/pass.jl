# Helper extensions.
Base.iterate(compact::CC.IncrementalCompact, state = nothing) =
   CC.iterate(compact, state)
Base.getindex(compact::CC.IncrementalCompact, idx) = CC.getindex(compact, idx)

Base.iterate(useref::CC.UseRefIterator, state...) = CC.iterate(useref, state...)
Base.getindex(useref::CC.UseRef) = CC.getindex(useref)

function refcount_pass!(ir::CC.IRCode)
    Core.println("=== RC ===")

    # For an IRCode, find `RefCounted` statements and record their
    # definitions and uses in that IR.
    ir, defuses = find_rcs!(ir)

    ir = debug!(ir)

    if !isempty(defuses)
        Core.println("Defuses:")
        for defuse in defuses
            Core.println(" - $defuse")
        end
    end

    # Given a CFG and defuses for it, determine exits, i.e.:
    # places, where `def` liveness ends or it escapes into another function.
    exits = determine_exits!(ir.cfg, defuses)

    if !isempty(exits)
        Core.println("Exits:")
        for (d, e, ce) in exits
            Core.println(" - $d: $e | $ce")
        end
    end

    ir = rc_insertion!(ir, defuses, exits)
    return ir
end

function debug!(ir)
    Core.println("=== debug ===")

    blocks = ir.cfg.blocks
    for (bid, block) in enumerate(blocks)
        for bstmt in block.stmts
            @show bid, block, ir.stmts[bstmt][:stmt]
        end
    end

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
    gc_preserve_begin = false
    gc_preserve_end = false
    attach_arcscan = false

    if stmt isa Expr
        if CC.is_known_call(stmt, Core.finalizer, compact)
            is_incrementing = false
        elseif CC.is_known_call(stmt, Core.getfield, compact)
            is_incrementing = false
            is_new_ref = true
        elseif CC.is_known_call(stmt, Core.setfield!, compact)
            attach_arcscan = true
        elseif CC.is_known_call(stmt, Core.memoryrefget, compact)
            is_new_ref = true
        elseif CC.isexpr(stmt, :gc_preserve_begin)
            is_incrementing = false
            gc_preserve_begin = true
        elseif CC.isexpr(stmt, :gc_preserve_end)
            is_incrementing = false
            gc_preserve_end = true
        end
    elseif stmt isa GlobalRef
        is_new_ref = true
    elseif stmt isa CC.PhiCNode
        is_new_ref = true
    end

    return (;
        is_incrementing, is_new_ref,
        gc_preserve_begin, gc_preserve_end, attach_arcscan)
end

function find_rcs!(ir::CC.IRCode)::Tuple{CC.IRCode, Vector{DefUse}}
    # TODO can `SSAValue` have multiple defuses, why vector?
    preserves = Dict{CC.SSAValue, Vector{DefUse}}()
    defuses = Dict{Union{CC.SSAValue, CC.Argument}, DefUse}()

    # Find `RefCounted` argtypes and mark them as `defs`.
    for (i, T) in enumerate(ir.argtypes)
        is_rctype(CC.widenconst(T)) || continue
        defuses[CC.Argument(i)] = DefUse(CC.Argument(i), Int[], Int[])

        Core.println("Argument $i is `RefCounted` $(CC.widenconst(T))")
    end

    compact = CC.IncrementalCompact(ir)
    for ((old_idx, idx), stmt) in compact
        Core.println("$old_idx, $idx, $stmt")
        inst::CC.Instruction = compact[CC.SSAValue(idx)]

        (;
            is_incrementing, is_new_ref,
            gc_preserve_begin, gc_preserve_end, attach_arcscan,
        ) = stmt_kind(stmt, compact)
        # Core.println("stmt kind: $is_incrementing, $is_new_ref, $gc_preserve_begin, $gc_preserve_end, $attach_arcscan")

        # If `stmt` is a call to `gc_preserve_end`, then extend
        # its arg lifetime up to this point (mark as a use).
        if gc_preserve_end
            val = only(stmt.args)
            preserve = get(preserves, val, nothing)
            if preserve ≢ nothing
                map(defuse -> push!(defuse.uses, idx), preserve)
            end
            continue
        end

        # Check if `inst` is a call to `RefCounted` ctor
        # or the return value of some function is `RefCounted`.
        # Example:
        #  - `y = RefCounted(:y)`.
        #  - `y = some_func()::RefCounted`.
        is_rc = is_rctype(CC.widenconst(inst[:type]))
        is_ϕ = stmt isa CC.PhiNode
        has_arcuse = false
        # TODO if value is not used, we lose tracking...
        # Core.println("is rc: $is_rc, is_ϕ: $is_ϕ, $(CC.widenconst(inst[:type]))")

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

                has_arcuse = true

                # Get defuses for `use`.
                # If it is `nothing`, then it is not a `RefCounted` obj
                # and we don't need to handle it.
                defuse = get(defuses, use, nothing)
                defuse ≡ nothing && continue
                @assert idx ∉ defuse.defs "$idx in defs: $(defuse.defs): $stmt, $use"
                @assert idx ∉ defuse.uses "$idx in uses: $(defuse.uses): $stmt, $use"
                Core.println("New RC use: $use -> $idx")
                push!(defuse.uses, idx)

                # If `stmt` is a `gc_preserve_begin` call, then add
                # current `defuse` to `preserves` to be able to extend
                # uses up until `gc_preserve_end` `stmt`.
                # Example:
                # gc_preserve_begin <- save `defuse` to `preserves`.
                # ...
                # gc_preserve_end   <- add `use` to `defuse` to extend lifetime.
                if gc_preserve_begin
                    preserve = get!(() -> DefUse[], preserves, CC.SSAValue(idx))
                    push!(preserve, defuse)
                end

                # TODO `arcuse` & `attach_arcscan`

                # Increment `RefCounted` counter on every use.
                if is_incrementing
                    insert_increment!(
                        CC.InsertBefore(compact, CC.SSAValue(idx)),
                        inst[:line], use)

                    Core.println("""Inserting increment for userefs:
                        - stmt: $stmt
                        - is_new_ref: $is_new_ref
                        - is_rc: $is_rc
                        - use: $use ($(typeof(use)))""")
                end
            end
        end

        if has_arcuse & attach_arcscan
            obj = stmt.args[2]
            @assert obj ≢ nothing
            insert_rcscan!(
                CC.InsertBefore(compact, CC.SSAValue(idx)),
                inst[:line], obj)

            Core.println("Attaching rcscan $obj $(typeof(obj)): $stmt")
        end

        if stmt isa CC.UpsilonNode
            # does not start a new value chain
            # XXX
            # Core.println("[???] UpsilonNode")
            continue
        end

        # If so, then it is considered as another `def`.
        if is_rc
            @assert !is_ϕ
            # TODO `is_additional_def`
            @assert !CC.isexpr(stmt, :(=))
            @assert !CC.is_known_call(stmt, setfield!, compact)

            val = CC.SSAValue(idx)
            defuse = get!(() -> DefUse(val, Int[], Int[]), defuses, val)
            # @assert idx ∉ defuse.defs "isrc $idx in defs: $(defuse.defs): $stmt, $val"
            # @assert idx ∉ defuse.uses "isrc $idx in uses: $(defuse.uses): $stmt, $val"
            push!(defuse.defs, idx)
            Core.println("New RC def: $val -> $idx")

            if is_new_ref
                insert_increment!(
                    CC.InsertHere(compact),
                    inst[:line], CC.SSAValue(idx))

                Core.println("""Inserting increment for rc:
                    - stmt: $stmt
                    - is_new_ref: $is_new_ref
                    - is_rc: $is_rc
                    - val: $idx""")
            end
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
        @show defuse
        live_ins::CC.BlockLiveness = CC.compute_live_ins(
            cfg, sort(defuse.defs), defuse.uses)

        @show live_ins
        bbs = copy(live_ins.def_bbs)
        isempty(live_ins.live_in_bbs) || append!(bbs, live_ins.live_in_bbs)

        exits = Int[]
        conditional_exits = Pair{Int, Int}[]

        for bb in bbs
            # For each `bb` take its successor BBs
            # and count how many of them are in `bbs`.
            succs = cfg.blocks[bb].succs
            live_succs = count(bb -> bb ∈ bbs, succs)
            @show succs, live_succs

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
            @show bb, length(blocks[bb].stmts)
            for idx in blocks[bb].stmts
                @show idx, ir.stmts[idx][:stmt]
            end

            block_stmts = blocks[bb].stmts
            terminator = last(block_stmts)
            inst = ir.stmts[terminator]
            stmt = inst[:stmt]
            # TODO ensure there is a successor block?
            if CC.is_known_call(stmt, RefCounted, ir)
                # TODO check if BB contains only one stmt and it is RefCounted ctor:
                # then either insert after this stmt or use immediate successor's first stmt
                #
                # either case is fine, since it is not a loop if it has only 1 stmt
                terminator = first(blocks[bb + 1].stmts)
                inst = ir.stmts[terminator]
                stmt = inst[:stmt]
            end

            insert_decrement!(
                CC.InsertBefore(ir, CC.SSAValue(terminator)),
                inst[:line], def)

            Core.println("""Inserting decrement:
                - stmt: $stmt
                - line $(inst[:line])
                - def: $def
                - exit: $bb
                - terminator: $terminator""")
        end

        @assert isempty(cond_exits)
        # TODO cond_exits
    end
    return CC.compact!(ir)
end
