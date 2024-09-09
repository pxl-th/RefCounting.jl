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
            Core.println("RefCounted finalizer")
            rc.counter != 0 && rc.dtor(rc.obj)
            return
        end
    end
end

RefCounted(obj::T, dtor) where T = RefCounted{T}(obj, dtor)
RefCounted(obj) = RefCounted(obj, (_) -> nothing)

# `refcount` pass will use this to detect `RefCounted` objects.
is_rctype(T::Type) = T !== Union{} && T <: RefCounted

function decrement!(rc::RefCounted)
    old, new = @atomic rc.counter - 1
    Core.println("[runtime] decrement!: $old -> $new")

    if new == 0
        rc.dtor(rc.obj)
    elseif new == typemax(UInt)
        error("RefCounted counter got below `0`!")
    end
    return
end

function increment!(rc::RefCounted)
    old, new = @atomic rc.counter + 1
    Core.println("[runtime] increment!: $old -> $new")
    old == 0 && error("Use-after-free: $old -> $new")
    return
end

function insert_decrement!(inserter, line, val)
    new_node = Expr(:call,
        GlobalRef(Core, :_call_within), nothing,
        GlobalRef(RefCounting, :decrement!), val)
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
