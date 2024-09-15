using Test
using RefCounting
using RefCounting: RefCounted

const CC = Core.Compiler

@testset "Exits" begin
    # function f()
    #     x = RefCounted() # stmt 1
    #     return           # stmt 2
    # end
    @testset "Single block function" begin
        bb1 = CC.BasicBlock(CC.StmtRange(1, 2))
        cfg = CC.CFG([bb1], [])

        defuse = RefCounting.DefUse(CC.SSAValue(1), [1], [])
        bl = CC.compute_live_ins(cfg, sort(defuse.defs), defuse.uses)
        @test bl.def_bbs == [1]

        exits = RefCounting.determine_exits!(cfg, [defuse])
        @test length(exits) == 1

        exit = exits[1]
        @test exit[1] == CC.SSAValue(1)
        @test exit[2] == [1]
        @test isempty(exit[3])
    end

    # function f()
    #     x = RefCounted() # stmt 1
    #     return x         # stmt 2
    # end
    @testset "Single block function, return RefCounted" begin
        bb1 = CC.BasicBlock(CC.StmtRange(1, 2))
        cfg = CC.CFG([bb1], [])

        defuse = RefCounting.DefUse(CC.SSAValue(1), [1], [2])
        bl = CC.compute_live_ins(cfg, sort(defuse.defs), defuse.uses)
        @test bl.def_bbs == [1]

        exits = RefCounting.determine_exits!(cfg, [defuse])
        @test length(exits) == 1

        exit = exits[1]
        @test exit[1] == CC.SSAValue(1)
        @test exit[2] == [1]
        @test isempty(exit[3])
    end
end

const COUNTER::Ref{Int} = Ref{Int}(-1)

function global_dtor(obj, counter)
    COUNTER[] = counter
    return
end

@testset "RefCounting" begin
    @testset "No assignment, no use" begin
        function f()
            RefCounted(:x, global_dtor)
            return
        end

        COUNTER[] = -1
        RefCounting.execute(f)
        @test COUNTER[] == 0
    end

    @testset "No use" begin
        function f()
            x = RefCounted(:x, global_dtor)
            return
        end

        COUNTER[] = -1
        RefCounting.execute(f)
        @test COUNTER[] == 0
    end

    @testset "For loop with 1 static iteration" begin
        # Loop is eliminated, resulting in BB with 1 statement.
        # In this case we insert dtor as a 1st stmt in the successor block.
        function f()
            for _ in 1:1
                x = RefCounted(:x, global_dtor)
            end
            return
        end

        COUNTER[] = -1
        RefCounting.execute(f)
        @test COUNTER[] == 0
    end

    @testset "For loop with 1 static iteration, multiple RefCounted objects within a loop" begin
        counters = fill(-1, 2)
        current_id = 1
        function array_dtor(obj, counter)
            counters[current_id] = counter
            current_id += 1
            return
        end

        # Loop is eliminated, resulting in BB with 1 statement.
        # In this case we insert dtor as a 1st stmt in the successor block.
        function f()
            for _ in 1:1
                RefCounted(:x, array_dtor)

                RefCounted(:y, array_dtor)
            end
            return
        end

        RefCounting.execute(f)
        @test all(counters .== 0)
    end

    @testset "For loop with 1 dynamic iteration" begin
        # Loop is not eliminated so we insert dtor call at the end of the loop BB.
        function f(n)
            for _ in 1:n
                x = RefCounted(:x, global_dtor)
            end
            return
        end

        COUNTER[] = -1
        RefCounting.execute(f, 1)
        @test COUNTER[] == 0
    end

    @testset "For loop with 10 iterations, creating 10 RefCounted objects" begin
        # Test that at the end of every loop iteration,
        # created RefCounted is destroyed.
        counters = fill(-1, 10)
        current_id = 1
        function array_dtor(obj, counter)
            counters[current_id] = counter
            current_id += 1
            return
        end

        function f(n)
            for _ in 1:n
                x = RefCounted(:x, array_dtor)
            end
            return
        end

        RefCounting.execute(f, 10)
        @test all(counters .== 0)
    end

    @testset "Use case" begin
        obj_val = -1
        function use(x)
            x.obj[] += 1
            obj_val = x.obj[]
            return x
        end

        function f()
            x = RefCounted(Ref(1), global_dtor)
            use(x)
            return
        end

        COUNTER[] = -1
        RefCounting.execute(f)
        @test COUNTER[] == 0
        @test obj_val == 2
    end

    @testset "Conditional use" begin
        obj_val = -1
        function use(x)
            x.obj[] += 1
            obj_val = x.obj[]
            return
        end

        function f(b)
            x = RefCounted(Ref(1), global_dtor)
            if b
                use(x)
            end
            return
        end

        COUNTER[] = -1
        RefCounting.execute(f, false)
        @test COUNTER[] == 0
        @test obj_val == -1

        COUNTER[] = -1
        RefCounting.execute(f, true)
        @test COUNTER[] == 0
        @test obj_val == 2
    end
end
