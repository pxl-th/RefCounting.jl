using RefCounting
using RefCounting: RefCounted

function f(x)
    return x
end

@noinline function use(x)
    x.obj[] += 1
    return
end

dtor(_, c) = Core.println("⋅ dtor: $c")

function f1(b)
    x = RefCounted(Ref(1), dtor)
    if b
        use(x)
    end
    return
end

function main()
    # RefCounting.execute(f, RefCounted(:x, dtor))
    RefCounting.execute(f1, true)
    return
end
main()
