using RefCounting
using RefCounting: RefCounted

function use(x)
    x.obj[] += 1
    return x
end

function use2(x)
    x.obj[] += 2
    return x
end

dtor(_, c) = Core.println("⋅ dtor: $c")

# TODO test from this
function f1(b)
    x = RefCounted(Ref(1), dtor)
    if b
        use(x)
    else
        use2(x)
    end
    use(x)
    return
end

function f2(b)
    x = RefCounted(Ref(1), dtor)
    # TODO x becomes `Nothing` if `b == false`.
    # Can we catch this?
    x = if b
        use(x)
    end
    use(x)
    return
end

function main()
    # RefCounting.execute(f, RefCounted(:x, dtor))
    RefCounting.execute(f1, true)
    # RefCounting.execute(f2, false)
    return
end
main()
