struct DefUse
    def::Union{CC.SSAValue, CC.Argument}
    # Vector of stmt IDs where a `def` is defined.
    defs::Vector{Int}
    # Vector of stmt IDs where a `def` is used.
    uses::Vector{Int}
end
