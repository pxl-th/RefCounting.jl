# Helper extensions.
Base.iterate(compact::CC.IncrementalCompact, state = nothing) =
   CC.iterate(compact, state)
Base.getindex(compact::CC.IncrementalCompact, idx) = CC.getindex(compact, idx)

function refcount_pass!(ir::CC.IRCode)
    ir = find_rcs!(ir)

    return ir
end

function find_rcs!(ir::CC.IRCode)
    Core.println()
    Core.println("---------------")
    defuses = Dict{Union{CC.SSAValue, CC.Argument}, DefUse}()

    # Find `RefCounted` argtypes and mark them as `defs` for `defuses`.
    for (i, T) in enumerate(ir.argtypes)
        wT = CC.widenconst(T)
        is_rctype(wT) || continue

        Core.println("Argument $i: $T (widened $wT, is_rctype $(is_rctype(wT)))")
        defuses[CC.Argument(i)] = DefUse(CC.Argument(i), [1], Int[])
    end

    # Core.println()
    # Core.println("Defuses after argtypes:")
    # for (def, defuse) in defuses
    #     Core.println(" - $def: $defuse")
    # end

    compact = CC.IncrementalCompact(ir)
    for ((old_idx, idx), stmt) in compact
        inst::CC.Instruction = compact[CC.SSAValue(idx)]

        # Check if `inst` is a call to `RefCounted` ctor
        # or the return value of some function is `RefCounted`.
        # Example:
        #  - `y = RefCounted(:y)`.
        iT = CC.widenconst(inst[:type])
        # If so, then it is considered as another `def`.
        if is_rctype(iT)
            Core.println("Returns `RefCounted`: stmt=$stmt")

            @show CC.isexpr(stmt, :(=))
            @show CC.is_known_call(stmt, setfield!, compact)
            # TODO
        end

        # Core.println("($old_idx, $idx) $stmt | $iT | $is_rc")
    end

    CC.non_dce_finish!(compact)
    CC.simple_dce!(compact)
    ir = CC.complete(compact)
    return ir
end
