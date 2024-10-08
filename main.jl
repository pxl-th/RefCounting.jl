using RefCounting
using RefCounting: RefCounted

function Base.setindex!(rc::RefCounted, v, i)
    rc.obj[i] = v
    return rc
end

function use(x)
    x.obj[] += 1
    return x
end

function use2(x)
    x.obj[] += 2
    return x
end

function use3(x)
    x.obj[] += 3
    return x
end

dtor(_, c) = Core.println("⋅ dtor: $c")

function setuse(r, x)
    setfield!(r, :x, x)
end

function f1()
    r = Ref{RefCounted{Int}}()
    x = RefCounted(1, dtor)
    setuse(r, x)
    # setfield!(r, :x, x)

    # y = RefCounted(2, dtor)
    # setfield!(r, :x, y)
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
    RefCounting.execute(f1)
    # RefCounting.execute(f2, false)
    return
end
main()
