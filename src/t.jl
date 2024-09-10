using RefCounting
using RefCounting: RefCounted

function f(x)
    return x
end

@noinline function use(x)
    x.obj[] += 1
    return
end

function f1()
    RefCounted(1, _ -> println("⋅ dtor ⋅"))
    return
end

function f2()
    x = RefCounted(1, _ -> println("⋅ dtor ⋅"))
    return
end

function loop()
    for i in 1:2
        # This finalizes every iteration.
        x = RefCounted(1, _ -> println("⋅ a dtor ⋅"))

        # This does not.
        RefCounted(1, _ -> println("⋅ b dtor ⋅"))
    end
    return
end

function main()
    # RefCounting.execute(f, RefCounted(:x))
    RefCounting.execute(f1)
    RefCounting.execute(f2)
    RefCounting.execute(loop)
    return
end
main()
