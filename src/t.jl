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

function f1()
    RefCounted(1, dtor)
    return
end

function f2()
    x = RefCounted(1, dtor)
    return
end

function loop(n)
    for i in 1:n
        # This finalizes every iteration.
        x = RefCounted(1, dtor)

        # # This does not.
        # RefCounted(1, dtor)
    end
    return
end

function main()
    # RefCounting.execute(f, RefCounted(:x, dtor))
    # RefCounting.execute(f1)
    # RefCounting.execute(f2)
    RefCounting.execute(loop, 1)
    return
end
main()
