"""
    deduplication_pass!(ir::CC.IRCode)

Go through IR statements and if any two consecutive statements
are increment -> decrement for the same `RefCounted` object, then remove them.
Example:

...
increment!(rc) <- removed
decrement!(rc) <- also removed
...

"""
function deduplication_pass!(ir::CC.IRCode)
    compact = CC.IncrementalCompact(ir)
    inc_ref = GlobalRef(@__MODULE__, :increment!)
    dec_ref = GlobalRef(@__MODULE__, :decrement!)

    delete_next = false
    for ((old_idx, idx), stmt) in compact
        if delete_next
            CC.delete_inst_here!(compact)
            delete_next = false
            continue
        end

        # Check if current `stmt` is a call to `increment!`.
        CC.is_known_call(stmt, Core._call_within, compact) || continue

        compiler = stmt.args[2]
        func = stmt.args[3]
        args = stmt.args[4:end]
        (compiler ≡ nothing && func == inc_ref) || continue

        # Check if `next_stmt` is a call to `decrement!`.
        next_stmt = ir[CC.SSAValue(old_idx + 1)][:stmt]
        CC.is_known_call(next_stmt, Core._call_within, ir) || continue

        next_compiler = next_stmt.args[2]
        next_func = next_stmt.args[3]
        next_args = next_stmt.args[4:end]
        (next_compiler ≡ nothing && next_func == dec_ref) || continue
        args == next_args || continue

        # Remove `stmt` and `next_stmt` if arguments are the same to both calls.
        CC.delete_inst_here!(compact)
        delete_next = true

        Core.println("""[deduplication] found consecutive inc-dec ops:
            - stmt: $stmt ($args)
            - next_stmt: $next_stmt ($next_args)
        """)
    end

    CC.non_dce_finish!(compact)
    CC.simple_dce!(compact)
    ir = CC.complete(compact)
    return ir
end
