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
    @testset "Single block function" begin
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

    @testset "For loop, no use" begin
        function f()
            for _ in 1:2 # TODO `1:1` loop results in `Unreachable reached`.
                x = RefCounted(:x, global_dtor)
            end
            return
        end

        COUNTER[] = -1
        RefCounting.execute(f)
        @test COUNTER[] == 0
    end
end
