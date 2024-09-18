mutable struct RefCounted{T}
    const obj::T
    const dtor
    @atomic counter::UInt

    function RefCounted{T}(obj::T, dtor) where T
        rc = new{T}(obj, dtor, UInt(1))

        # NOTE: Finalizer returns `rc`, but if unused we lose tracking.
        # E.g.:
        #     RefCounted(1) <- lose tracking
        # x = RefCounted(1) <- don't lose tracking
        return finalizer(rc) do rc
            Core.println("rc finalizer")
            rc.counter != 0 && rc.dtor(rc.obj, rc.counter)
            return
        end
    end
end

RefCounted(obj::T, dtor) where T = RefCounted{T}(obj, dtor)
RefCounted(obj) = RefCounted(obj, (_, _) -> nothing)

# `refcount` pass will use this to detect `RefCounted` objects.
is_rctype(T::Type) = T !== Union{} && T <: RefCounted

function decrement!(rc::RefCounted)
    old, new = @atomic rc.counter - 1

    Core.println("decrement: $old -> $new")

    if new == 0
        rc.dtor(rc.obj, rc.counter)
    elseif new == typemax(UInt)
        error("RefCounted counter got below `0`!")
    end
    return
end

function decrement_ifnot!(rc::RefCounted, cond)
    if !cond
        decrement!(rc)
    end
end

function decrement_conditional!(rc::RefCounted, cond)
    if cond
        decrement!(rc)
    end
end

function increment!(rc::RefCounted)
    old, new = @atomic rc.counter + 1
    Core.println("increment: $old -> $new")
    old == 0 && error("Use-after-free: $old -> $new")
    return
end

const SCANNED = Base.WeakKeyDict{Any, Bool}()

function rc_scan!(@nospecialize(x))
    Core.println("RC scanning $x $(typeof(x))")

    @lock SCANNED begin
        haskey(SCANNED, x) && return
        SCANNED[x] = true
    end

    for f in 1:fieldcount(typeof(x))
        v = Base.getfield(x, f)
        if v isa RefCounted
            Core.println("[arcscan] found RefCounted")
            decrement!(v)
        end
    end
end

function insert_decrement!(inserter, line, val, attach_after)
    @assert inserter isa CC.InsertBefore
    new_node = Expr(:call,
        GlobalRef(Core, :_call_within), nothing,
        GlobalRef(RefCounting, :decrement!), val)
    new_inst = CC.NewInstruction(new_node, Nothing, CC.NoCallInfo(), line, nothing)
    CC.insert_node!(inserter.src, inserter.pos, new_inst, attach_after)
end

function insert_ifnot_decrement!(inserter, line, val, cond)
    new_node = Expr(:call,
        GlobalRef(Core, :_call_within), nothing,
        GlobalRef(RefCounting, :decrement_ifnot!), val, cond)
    new_inst = CC.NewInstruction(new_node, Nothing, CC.NoCallInfo(), line, nothing)
    inserter(new_inst)
end

function insert_conditional_decrement!(inserter, line, val, cond)
    new_node = Expr(:call,
        GlobalRef(Core, :_call_within), nothing,
        GlobalRef(RefCounting, :decrement_conditional!), val, cond)
    new_inst = CC.NewInstruction(new_node, Nothing, CC.NoCallInfo(), line, nothing)
    inserter(new_inst)
end

function insert_increment!(inserter, line, val)
    new_node = Expr(:call,
        GlobalRef(Core, :_call_within), nothing,
        GlobalRef(RefCounting, :increment!), val)
    new_inst = CC.NewInstruction(new_node, Nothing, CC.NoCallInfo(), line, nothing)
    inserter(new_inst)
end

function insert_rcscan!(inserter, line, val)
    new_node = Expr(:call,
        GlobalRef(Core, :finalizer),
        GlobalRef(RefCounting, :rc_scan!), val)
    new_inst = CC.NewInstruction(new_node, Nothing, CC.NoCallInfo(), line, nothing)
    inserter(new_inst)
end
