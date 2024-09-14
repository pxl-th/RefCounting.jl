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

function loop1()
    for i in 1:1
        # x = RefCounted(1, dtor)
        RefCounting.RefCounted(1, dtor)

        RefCounting.RefCounted(1, dtor)
    end
    return
end

function loop2(n)
    for i in 1:n
        x = RefCounted(1, dtor)

        RefCounted(1, dtor)
    end
    return
end

function main()
    # RefCounting.execute(f, RefCounted(:x, dtor))
    # RefCounting.execute(f1)
    # RefCounting.execute(f2)
    RefCounting.execute(loop1)
    # RefCounting.execute(loop2, 2)
    return
end
main()
