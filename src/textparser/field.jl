using QuickTypes

abstract AbstractToken{T}
fieldtype{T}(::AbstractToken{T}) = T
fieldtype{T}(::Type{AbstractToken{T}}) = T
fieldtype{T<:AbstractToken}(::Type{T}) = fieldtype(supertype(T))


# Numberic parsing
@qtype Numeric{T}(
    decimal::Char='.'
  , thousands::Char=','
) <: AbstractToken{T}

Numeric{N<:Number}(::Type{N}; kws...) = Numeric{N}(;kws...)
fromtype{N<:Number}(::Type{N}) = Numeric(N)

### Unsigned integers

@inline function tryparsenext{T<:Signed}(::Numeric{T}, str, i, len)
    R = Nullable{T}
    @chk2 sign, i = tryparsenext_sign(str, i, len)
    @chk2 x, i = tryparsenext_base10(T, str, i, len)

    @label done
    return R(sign*x), i

    @label error
    return R(), i
end

@inline function tryparsenext{T<:Unsigned}(::Numeric{T}, str, i, len)
    tryparsenext_base10(T,str, i, len)
end

@inline function tryparsenext{F<:AbstractFloat}(::Numeric{F}, str, i, len)
    R = Nullable{F}
    f = 0.0
    @chk2 sign, i = tryparsenext_sign(str, i, len)
    x=0

    i > len && @goto error
    c, ii = next(str, i)
    if c == '.'
        i=ii
        @goto dec
    end
    @chk2 x, i = tryparsenext_base10(Int, str, i, len)
    i > len && @goto done
    @inbounds c, ii = next(str, i)

    c != '.' && @goto done
    @label dec
    @chk2 y, i = tryparsenext_base10(Int, str, ii, len)
    f = y / 10.0^(i-ii)

    i > len && @goto done
    c, ii = next(str, i)
    if c == 'e' || c == 'E'
        @chk2 exp, i = tryparsenext(Numeric(Int), str, ii, len)
        return R(sign*(x+f) * 10.0^exp), i
    end

    @label done
    return R(sign*(x+f)), i

    @label error
    return R(), i
end

using Base.Test
let
    @test tryparsenext(fromtype(Float64), "21", 1, 2) |> unwrap== (21.0,3)
    @test tryparsenext(fromtype(Float64), ".21", 1, 3) |> unwrap== (.21,4)
    @test tryparsenext(fromtype(Float64), "1.21", 1, 4) |> unwrap== (1.21,5)
    @test tryparsenext(fromtype(Float64), "-1.21", 1, 5) |> unwrap== (-1.21,6)
    @test tryparsenext(fromtype(Float64), "-1.5e-12", 1, 8) |> unwrap == (-1.5e-12,9)
    @test tryparsenext(fromtype(Float64), "-1.5E-12", 1, 8) |> unwrap == (-1.5e-12,9)
end


@qimmutable Str{T}(
    output_type::Type{T}
    ; endchar::Char=','
  , includenewline=false
  , escapechar::Char='\\'
) <: AbstractToken{T}

fromtype{S<:AbstractString}(::Type{S}) = Str(S)

function tryparsenext{T}(s::Str{T}, str, i, len)
    R = Nullable{T}
    i > len && return R(), i
    p = ' '
    i0 = i
    while true
        i > len && break
        c, ii = next(str, i)
        if (c == s.endchar && p != s.escapechar) ||
            (!s.includenewline && isnewline(c))
            break
        end
        i = ii
        p = c
    end

    return R(_substring(T, str, i0, i-1)), i
end

@inline function _substring(::Type{String}, str, i, j)
    str[i:j]
end

@inline function _substring{T}(::Type{SubString{T}}, str, i, j)
    SubString(str, i, j)
end

using WeakRefStrings
@inline function _substring{T}(::Type{WeakRefString{T}}, str, i, j)
    WeakRefString(pointer(str.data)+(i-1), (j-i+1))
end

let
    for (s,till) in [("test  ",7), ("\ttest ",7), ("test\nasdf", 5), ("test,test", 5), ("test\\,test", 11)]
        @test tryparsenext(Str(String), s) |> unwrap == (s[1:till-1], till)
    end
    for (s,till) in [("test\nasdf", 10), ("te\nst,test", 6)]
        @test tryparsenext(Str(String, includenewline=true), s) |> unwrap == (s[1:till-1], till)
    end
    @test tryparsenext(Str(String, includenewline=true), "") |> failedat == 1
end


immutable LiteStr
    range::UnitRange{Int}
end
fromtype(::Type{LiteStr}) = Str{LiteStr}()

@inline function _substring(::Type{LiteStr}, str, i, j)
    LiteStr(i:j)
end


### Field parsing

@qtype Field{T,S<:AbstractToken}(
    inner::S
  ; ignore_init_whitespace::Bool=true
  , ignore_end_whitespace::Bool=true
  , quoted::Bool=false
  , quotechar::Char='\"'
  , escapechar::Char='\\'
  , eoldelim::Bool=false
  , spacedelim::Bool=false
  , delim::Char=','
  , output_type::Type{T}=fieldtype(inner)
) <: AbstractToken{T}

function tryparsenext{T}(f::Field{T}, str, i, len)
    R = Nullable{T}
    i > len && @goto error
    if f.ignore_init_whitespace
        while i <= len
            @inbounds c, ii = next(str, i)
            !iswhitespace(c) && break
            i = ii
        end
    end
    @chk2 res, i = tryparsenext(f.inner, str, i, len)

    i0 = i
    if f.ignore_end_whitespace
        while i <= len
            @inbounds c, ii = next(str, i)
            !iswhitespace(c) && break
            i = ii
        end
    end

    f.spacedelim && i > i0 && @goto done
    f.delim == '\t' && c == '\t' && @goto done

    if i > len
        if f.eoldelim
            @goto done
        else
            @goto error
        end
    end

    @inbounds c, ii = next(str, i)

    if f.eoldelim
        if c == '\r'
            i=ii
            c, ii = next(str, i)
            if c == '\n'
                i=ii
            end
            @goto done
        elseif c == '\n'
            i=ii
            c, ii = next(str, i)
            if c == '\r'
                i=ii
            end
            @goto done
        end
        @goto error
    end

    c != f.delim && @goto error # this better be the delim!!
    i = ii

    @label done
    return R(res), i

    @label error
    return R(), i
end
