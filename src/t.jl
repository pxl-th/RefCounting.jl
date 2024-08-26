using RefCounting
using RefCounting: RefCounted

function f(x)
    y = RefCounted(:g)
    return x
end

function main()
    RefCounting.execute(f, RefCounted(:x))
    return
end
main()
