module RefCounting

const CC = Core.Compiler

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
    CC.@pass "refcount"  ir = refcount_pass!(ir)
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

include("rc.jl")
include("defuse.jl")
include("pass.jl")

function __init__()
    COMPILER_WORLD[] = ccall(:jl_get_tls_world_age, UInt, ())
end

precompile(CC.typeinf_ext_toplevel, (RCInterpreter, CC.MethodInstance))

end
