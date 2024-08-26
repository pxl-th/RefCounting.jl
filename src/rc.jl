mutable struct RefCounted{T}
    const obj::T
    const dtor
    @atomic counter::UInt

    function RefCounted{T}(obj::T, dtor) where T
        rc = new{T}(obj, dtor, UInt(1))
        finalizer(rc) do rc
            rc.counter != 0 && rc.dtor(rc.obj)
            return
        end
        return rc
    end
end

RefCounted(obj::T, dtor) where T = RefCounted{T}(obj, dtor)
RefCounted(obj) = RefCounted(obj, (_) -> nothing)

is_rctype(T::Type) = T !== Union{} && T <: RefCounted
