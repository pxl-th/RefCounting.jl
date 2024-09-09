using RefCounting
using RefCounting: RefCounted

# function f(x)
#     y = RefCounted(:g)
#     return x
# end

@noinline function use(x)
    x.obj[] += 1
    return
end

function f()
    RefCounted(1, _ -> println("⋅ dtor ⋅"))
    return
end

function loop()
    for i in 1:10
        # This finalizes every iteration.
        x = RefCounted(1, _ -> println("⋅ dtor ⋅"))

        # This does not.
        RefCounted(1, _ -> println("⋅ dtor ⋅"))
    end
    return
end

function main()
    # RefCounting.execute(f, RefCounted(:x))
    RefCounting.execute(f)
    return
end
main()
