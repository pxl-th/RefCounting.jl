# Helper extensions.
Base.iterate(compact::CC.IncrementalCompact, state = nothing) =
   CC.iterate(compact, state)
Base.getindex(compact::CC.IncrementalCompact, idx) = CC.getindex(compact, idx)

Base.iterate(useref::CC.UseRefIterator, state...) = CC.iterate(useref, state...)
Base.getindex(useref::CC.UseRef) = CC.getindex(useref)

function refcount_pass!(ir::CC.IRCode)
    Core.println()
    Core.println()
    Core.println("=== RC ===")

    ir = debug!(ir)

    # For an IRCode, find `RefCounted` statements and record their
    # definitions and uses in that IR.
    ir, defuses = find_rcs!(ir)

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
            Core.println("bid $bid | stmt $bstmt | $(repr(ir.stmts[bstmt][:stmt]))")
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
        inst::CC.Instruction = compact[CC.SSAValue(idx)]
        @show typeof(stmt), typeof(inst), stmt

        (;
            is_incrementing, is_new_ref,
            gc_preserve_begin, gc_preserve_end, attach_arcscan,
        ) = stmt_kind(stmt, compact)

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

        # If ϕ stmt returns a `RefCounted` it also starts a new chain.
        # Process each of its edges.
        if is_rc && is_ϕ
            ϕ = stmt::CC.PhiNode
            cfg = compact.ir.cfg
            ϕ_bb = CC.block_for_inst(cfg, old_idx)
            Core.println("ϕ node handling: $(length(ϕ.edges)) edges")

            # Go through ϕ edges BBs and mark terminator in those BBs
            # as a use.
            # Increment counter as well.
            for (edge_id, from_bb) in enumerate(ϕ.edges)
                terminator = last(cfg.blocks[from_bb].stmts)
                val = ϕ.values[edge_id]

                # Insert `increment` before terminator `stmt`.
                peek = CC.CompactPeekIterator(compact, terminator, terminator)
                terminator_inst, _ = CC.iterate(peek)

                if (
                    terminator_inst isa CC.GotoNode
                    # one of the branches does nothing, e.g.:
                    # if b
                    #     use(x)
                    # else
                    #     x
                    # end
                    || terminator_inst isa Nothing
                    # terminator stmt is a regular instruction,
                    # which may also be a `def`.
                    || terminator_inst isa Expr # TODO is this safe? does it mean it is a regular inst?
                    || terminator_inst isa CC.PhiNode
                )
                    terminator_stmt = compact[CC.SSAValue(terminator)][:stmt]
                    is_return_stmt = terminator_stmt isa Core.ReturnNode
                    @assert !is_return_stmt
                    # attach_after = !is_return_stmt && is_def_terminator

                    # Attach increment after if stmt is either nothing
                    # or a regular instruction (which may also be a def).
                    # Otherwise, it is a goto node and we want to insert
                    # before.
                    attach_after = (
                        terminator_inst isa Nothing
                        || terminator_inst isa Expr
                        || terminator_inst isa CC.PhiNode # TODO ok to always insert after?
                    )
                    insert_increment!(
                        CC.InsertBefore(compact, CC.SSAValue(terminator)),
                        inst[:line], val, attach_after)

                    # TODO why use `inst[:line]` if we insert before terminator?
                    # shouldn't we use terminator's line?

                    Core.println("""Inserting increment in ϕ node:
                        - attach_after: $attach_after
                        - stmt: $stmt
                        - edge_id: $edge_id
                        - val: $val
                        - line: $(inst[:line])
                        - terminator: $terminator
                        - terminator stmt: $(compact[CC.SSAValue(terminator)][:stmt])
                    """)
                else
                    if !(terminator_inst isa CC.GotoIfNot)
                        Core.println("""[error] Unhandled control flow in ϕ node:
                            - edge_id: $edge_id
                            - val: $val
                            - terminator inst: $(typeof(terminator_inst))
                            - terminator stmt: $(compact[CC.SSAValue(terminator)][:stmt])
                        """)
                        continue
                    end

                    gotoifnot = terminator_inst::CC.GotoIfNot
                    cond = gotoifnot.cond
                    if gotoifnot.dest == ϕ_bb
                        insert_ifnot_increment!(
                            CC.InsertBefore(compact, CC.SSAValue(terminator)),
                            inst[:line], val, cond)
                        Core.println("""Inserting ifnot increment in ϕ node:
                            - stmt: $stmt
                            - edge_id / val: $edge_id / $val
                            - line: $(inst[:line])
                            - terminator: $terminator
                            - terminator stmt: $(compact[CC.SSAValue(terminator)][:stmt])
                        """)
                    else
                        # @assert false
                        insert_conditional_increment!(
                            CC.InsertBefore(compact, CC.SSAValue(terminator)),
                            inst[:line], val, cond)
                        Core.println("""Inserting conditional increment in ϕ node:
                            - stmt: $stmt
                            - edge_id / val: $edge_id / $val
                            - line: $(inst[:line])
                            - terminator: $terminator
                            - terminator stmt: $(compact[CC.SSAValue(terminator)][:stmt])
                        """)
                    end
                end

                # Mark `terminator` as a use for ϕ i-th `val` (if it is not a def already).
                defuse = get!(() -> DefUse(val, Int[], Int[]), defuses, val)
                if terminator ∉ defuse.defs
                    push!(defuse.uses, terminator)
                end
            end
        # If `stmt` is not `RefCounted` or not a `CC.PhiNode`,
        # record all `uses` of it.
        else
            if attach_arcscan
                holder_obj = stmt.args[2]
                @show holder_obj
                @show typeof(holder_obj)
                if holder_obj isa CC.SSAValue
                    inst = compact[holder_obj]
                    @show inst[:stmt]
                    # TODO if it is an Argument, check its type
                    @show CC.widenconst(inst[:type]) # TODO check if WeakRef and do not mark as use its userefs
                end
            end

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
                @assert idx ∉ defuse.defs "$idx in defs: $(defuse.defs): $stmt, $use"
                @assert idx ∉ defuse.uses "$idx in uses: $(defuse.uses): $stmt, $use"
                Core.println("New RC use: $use -> $idx")
                push!(defuse.uses, idx)

                # TODO test
                has_arcuse = true

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

        # Insert `finalizer(rc_scan!, obj)` before `setfield!` stmt.
        # So when the `obj` is dead, its refcount is decreased.
        # TODO this still relies on GC...
        #
        # If in the meantime the obj was assigned again,
        # we'll double decrease same RefCounted.
        #
        # TODO + insert rc_scan_decrease! that decreases previously assigned obj.
        # TODO - track refcounted holders, find exits for them and decrease counter there?
        # TODO - handle WeakRef (don't count as use)
        if has_arcuse & attach_arcscan
            obj = stmt.args[2]
            @assert obj ≢ nothing
            # insert_rcscan!(
            insert_immediate_rcscan!(
                CC.InsertBefore(compact, CC.SSAValue(idx)),
                inst[:line], obj)

            Core.println("""Attaching rcscan:
                - obj: $obj $(typeof(obj))
                - idx: $idx
                - line: $(inst[:line])
                - stmt: $stmt
            """)
        end

        if stmt isa CC.UpsilonNode
            # does not start a new value chain
            # XXX
            # Core.println("[???] UpsilonNode")
            continue
        end

        # If so, then it is considered as another `def`.
        if is_rc
            # TODO ???
            # @assert !is_ϕ

            # TODO do we need extra_def? Since `setfield!` returns the same object.
            extra_def = false
            if CC.is_known_call(stmt, setfield!, compact)
                extra_def = true
                val = stmt.args[4]
                @assert haskey(defuses, val)
            elseif CC.isexpr(stmt, :(=))
                # @assert false
                extra_def = true
                val = stmt.args[2]
                @assert haskey(defuses, val)
            else
                val = CC.SSAValue(idx)
            end

            defuse = get!(() -> DefUse(val, Int[], Int[]), defuses, val)
            @assert idx ∉ defuse.defs "isrc $idx in defs: $(defuse.defs): $stmt, $val"
            # @assert idx ∉ defuse.uses "isrc $idx in uses: $(defuse.uses): $stmt, $val"
            if idx ∉ defuse.uses
                push!(defuse.defs, idx)
                Core.println("New RC def: $val -> $idx")
            end

            # If `stmt` is something like:
            # r[] = x::RefCounted
            #
            # Then set `defs` both for `setfield!` arg and for the current `stmt`.
            # Ensuring that current stmt does not yet exist in `defuses`.
            if extra_def
                val = CC.SSAValue(idx)
                @assert !haskey(defuses, val)
                defuses[val] = defuse
                Core.println("Extra RC def: $val -> $idx")
            end

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

    Core.println("=== exits ===")

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
                other_bb ∈ bbs && continue
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
            block_stmts = blocks[bb].stmts
            terminator = last(block_stmts)
            inst = ir.stmts[terminator]
            stmt = inst[:stmt]
            line = inst[:line]

            is_return_stmt = stmt isa Core.ReturnNode
            is_def_terminator = def isa CC.SSAValue ?
                ir[def][:line] == line :
                false

            # Attach decrement after `terminator`
            # if `def` is on the same line as `terminator`.
            #
            # This may happen in a case where a loop is optimized away, e.g.:
            # for i in 1:1
            #     RefCounted(1, dtor)
            # end
            #
            # Or in case where `use` returns `x` under-the-hood:
            # if b
            #     ...
            #     use(x)
            # end
            attach_after = is_def_terminator && !is_return_stmt
            insert_decrement!(
                CC.InsertBefore(ir, CC.SSAValue(terminator)),
                line, def, attach_after)

            Core.println("""Inserting decrement:
                - attach_after: $attach_after
                - $(typeof(stmt))
                - stmt: $stmt
                - line $line
                - inst typ: $(inst[:type])
                - def: $def
                - def stmt: $(def isa CC.SSAValue ? ir[def][:stmt] : def)
                - exit: $bb
                - terminator: $terminator""")
        end

        for (bb, other_bb) in cond_exits
            terminator = last(blocks[bb].stmts)
            inst = ir.stmts[terminator]
            if !(inst[:stmt] isa CC.GotoIfNot)
                Core.println("Unhandled control-flow: $(inst[:stmt])")
                continue
            end

            gotoifnot = inst[:stmt]::CC.GotoIfNot
            cond = gotoifnot.cond
            # If `cond` is `true` it is handled by unconditional exits.
            # For `false` we need to insert conditional decrement.
            if gotoifnot.dest == other_bb
                insert_ifnot_decrement!(
                    CC.InsertBefore(ir, CC.SSAValue(terminator)),
                    inst[:line], def, cond)
                Core.println("""Inserting ifnot decrement:
                    - stmt: $gotoifnot
                    - def: $def
                    - cond: $cond
                    - bb -> other_bb: $bb -> $other_bb
                """)
            else
                insert_conditional_decrement!(
                    CC.InsertBefore(ir, CC.SSAValue(terminator)),
                    inst[:line], def, cond)
                Core.println("""Inserting conditional decrement:
                    - stmt: $gotoifnot
                    - def: $def
                    - cond: $cond
                    - bb -> dest: $bb -> $(gotoifnot.dest) (!= $other_bb other_bb)
                """)
            end
        end
    end
    return CC.compact!(ir)
end
