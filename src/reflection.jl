function code_rc(f, types=(); kwargs...)
    Base.code_ircode(f, types; interp=RCInterpreter(RCCompiler()), kwargs...)
end
