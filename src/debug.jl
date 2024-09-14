module RC

const CC = Core.Compiler

mutable struct RefCounted
    x::Int
    @atomic counter::UInt

    function RefCounted()
        return new(1, 0x1)
    end
end

is_rctype(T::Type) = T !== Union{} && T <: RefCounted

function decrement!(rc::RefCounted)
    old, new = @atomic rc.counter - 1
    Core.println("counter: $old -> $new")
    return
end

const COMPILER_WORLD = Ref{UInt}(0)

struct RCCompiler <: CC.AbstractCompiler end

CC.abstract_interpreter(rcc::RCCompiler, world::UInt) =
    RCInterpreter(rcc; world)

CC.compiler_world(::RCCompiler) = COMPILER_WORLD[]

struct RCInterpreter <: CC.AbstractInterpreter
    world::UInt
    inf_params::CC.InferenceParams
    opt_params::CC.OptimizationParams
    inf_cache::Vector{CC.InferenceResult}
    code_cache::CC.InternalCodeCache

    compiler::RCCompiler

    function RCInterpreter(rcc::RCCompiler;
        world::UInt = Base.get_world_counter(),
        inf_params::CC.InferenceParams = CC.InferenceParams(),
        opt_params::CC.OptimizationParams = CC.OptimizationParams(),
        inf_cache::Vector{CC.InferenceResult} = CC.InferenceResult[],
        code_cache::CC.InternalCodeCache = CC.InternalCodeCache(rcc),
    )
        return new(world, inf_params, opt_params, inf_cache, code_cache, rcc)
    end
end

CC.InferenceParams(rci::RCInterpreter) = rci.inf_params
CC.OptimizationParams(rci::RCInterpreter) = rci.opt_params
CC.get_inference_cache(rci::RCInterpreter) = rci.inf_cache
CC.code_cache(rci::RCInterpreter) = CC.WorldView(rci.code_cache, CC.WorldRange(rci.world))
CC.cache_owner(rci::RCInterpreter) = rci.compiler

CC.get_inference_world(rci::RCInterpreter) = rci.world
CC.get_world_counter(rci::RCInterpreter) = rci.world

function execute(f, args...; kwargs...)
    @nospecialize
    Base.invoke_within(RCCompiler(), f, args...; kwargs...)
end

function CC.optimize(
    rci::RCInterpreter, opt::CC.OptimizationState, caller::CC.InferenceResult,
)
    ir = run_passes_ipo_safe!(opt.src, opt, caller)
    CC.ipo_dataflow_analysis!(rci, ir, caller)
    return CC.finish(rci, opt, ir, caller)
end

function run_passes_ipo_safe!(
    ci::CC.CodeInfo, opt::CC.OptimizationState, caller::CC.InferenceResult,
    optimize_until::Union{Integer, AbstractString, Nothing} = nothing,
)
    # NOTE:
    # The pass name MUST be unique for `optimize_until` to work.

    __stage__ = 0 # used by @pass
    CC.@pass "convert"   ir = CC.convert_to_ircode(ci, opt)
    CC.@pass "slot2reg"  ir = CC.slot2reg(ir, ci, opt)
    CC.@pass "compact 1" ir = CC.compact!(ir)

    # CC.@pass "custom pass"  ir = pass!(ir)
    CC.@pass "custom pass"  ir = pass2!(ir)

    CC.@pass "Inlining"  ir = CC.ssa_inlining_pass!(ir, opt.inlining, ci.propagate_inbounds)
    CC.@pass "compact 2" ir = CC.compact!(ir)
    CC.@pass "SROA"      ir = CC.sroa_pass!(ir, opt.inlining)
    CC.@pass "ADCE"      (ir, made_changes) = CC.adce_pass!(ir, opt.inlining)
    if made_changes
        CC.@pass "compact 3" ir = CC.compact!(ir, true)
    end
    if CC.is_asserts()
        CC.@timeit "verify 3" begin
            CC.verify_ir(ir, true, false, CC.optimizer_lattice(opt.inlining.interp))
            CC.verify_linetable(ir.linetable)
        end
    end
    @label __done__ # used by @pass
    return ir
end

# Helper extensions.
Base.iterate(compact::CC.IncrementalCompact, state = nothing) =
   CC.iterate(compact, state)
Base.getindex(compact::CC.IncrementalCompact, idx) = CC.getindex(compact, idx)

function pass!(ir::CC.IRCode)
    compact = CC.IncrementalCompact(ir)

    for ((old_idx, idx), stmt) in compact
        (stmt isa Expr && CC.is_known_call(stmt, Core.println, compact)) || continue

        inst = compact[CC.SSAValue(idx)]
        line = inst[:line]

        inserter = CC.InsertBefore(compact, CC.SSAValue(idx))
        new_node = Expr(:call, GlobalRef(Core, :println), 42)
        new_inst = CC.NewInstruction(new_node, Nothing, CC.NoCallInfo(), line, nothing)
        inserter(new_inst)
    end

    CC.non_dce_finish!(compact)
    CC.simple_dce!(compact)
    ir = CC.complete(compact)
    return ir
end

function pass2!(ir::CC.IRCode)
    defs = CC.SSAValue[]
    insert = false

    for (idx, inst) in enumerate(ir.stmts)
        TT = CC.widenconst(inst[:type])
        is_rc = is_rctype(TT)
        stmt = inst[:stmt]

        (stmt isa Expr && CC.is_expr(stmt, :gc_preserve_begin)) && continue
        (stmt isa Expr && CC.is_expr(stmt, :gc_preserve_end)) && continue

        if is_rc
            @show idx, TT, is_rc stmt
            push!(defs, CC.SSAValue(idx))
            insert = true
            continue
        end

        insert || continue

        # (stmt isa Expr && CC.is_known_call(stmt, Core.println, ir)) || continue

        # inserter = CC.InsertBefore(ir, CC.SSAValue(idx))
        # new_node = Expr(:call, GlobalRef(Core, :println), 42)
        # new_inst = CC.NewInstruction(new_node, Nothing, CC.NoCallInfo(), inst[:line], nothing)

        @show idx, TT, is_rc stmt

        inserter = CC.InsertBefore(ir, CC.SSAValue(idx))
        val = pop!(defs)
        new_node = Expr(:call,
            GlobalRef(Core, :_call_within), nothing,
            GlobalRef(RC, :decrement!), val)
        new_inst = CC.NewInstruction(new_node,
            Nothing, CC.NoCallInfo(), inst[:line], nothing)
        inserter(new_inst)

        insert = false
    end
    return CC.compact!(ir)
end

function __init__()
    COMPILER_WORLD[] = ccall(:jl_get_tls_world_age, UInt, ())
end

end

using .RC

function f()
    for i in 1:1
        x = RC.RefCounted()
        Core.println(1)
    end
end

function main()
    RC.execute(f)
    return
end
main()
