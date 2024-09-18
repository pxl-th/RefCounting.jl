using RefCounting
using RefCounting: RefCounted

function use(x)
    x.obj[] += 1
    return x
end

dtor(_, c) = Core.println("⋅ dtor: $c")

function f1(b)
    x = RefCounted(Ref(1), dtor)
    x = if b
        use(x)
    else
        x
    end
    use(x)
    return
end

function main()
    # RefCounting.execute(f, RefCounted(:x, dtor))
    RefCounting.execute(f1, true)
    return
end
main()
