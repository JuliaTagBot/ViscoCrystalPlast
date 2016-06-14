# Utilities that might be useful
const DEBUG = false

# Checks that a line is equal to another, if not
# throws an informational error message
function check_line(line, check)
    if check != ""
        if line != check
            error("expected $check, got $line")
        end
    end
end

# Returns the next line without advancing in the
# buffer
function peek_line(f, check = "")
    m = mark(f)
    line = strip(readline(f))
    check_line(line, check)
    DEBUG && println("Peeked: ", line)
    seek(f, m)
    return line
end

# Returns the next line and advance in the buffer
function eat_line(f, check = "")
    line = strip(readline(f))
    check_line(line, check)
    DEBUG && println("Ate: ", line)
    return line
end

#
function parse_line(line, types::Vararg{DataType})
    if contains(line, ",")
        lsplit = split(line, [','])
    else
        lsplit = split(line)
    end
    @assert length(lsplit) == length(types)
    return [parse(types[i], lsplit[i]) for i in 1:length(types)]
end

include("ABAQUS.jl")
include("Gmsh.jl")