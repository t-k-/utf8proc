# Following work by @jiahao, we compute character widths using a combination of
#   * advance widths from GNU Unifont (advance width 512 = 1 en)
#   * UAX 11: East Asian Width
#   * a few exceptions as needed
# Adapted from http://nbviewer.ipython.org/gist/jiahao/07e8b08bf6d8671e9734
#
# Requires Julia (obviously) and FontForge.

#############################################################################
# Julia 0.3/0.4 compatibility (taken from Compat package)
if VERSION < v"0.4.0-dev+1419"
    const UInt16 = Uint16
end

CharWidths = Dict{Int,Int}()

#############################################################################
# Widths from GNU Unifont

universion=get(ENV, "UNIFONT_VERSION", "7.0.06")
for fontfile in ["unifont-$universion", "unifont_upper-$universion"]
    isfile("$fontfile.ttf") || download("http://unifoundry.com/pub/unifont-$universion/font-builds/$fontfile.ttf", "$fontfile.ttf")
    isfile("$fontfile.sfd") || run(`fontforge -lang=ff -c "Open(\"$fontfile.ttf\");Save(\"$fontfile.sfd\");Quit(0);"`)
end

#Read sfdfile for character widths
function parsesfd(filename::String, CharWidths::Dict{Int,Int}=Dict{Int,Int}())
    state=:seekchar
    lineno = 0
    for line in readlines(open(filename))
        lineno += 1
        if state==:seekchar         #StartChar: nonmarkingreturn
            if contains(line, "StartChar: ")
                codepoint = nothing
                width = nothing
                state = :readdata
            end
        elseif state==:readdata #Encoding: 65538 -1 2, Width: 1024
            contains(line, "Encoding:") && (codepoint = int(split(line)[3]))
            contains(line, "Width:") && (width = int(split(line)[2]))
            if codepoint!=nothing && width!=nothing && codepoint >= 0
                CharWidths[codepoint]=div(width, 512) # 512 units to the en
                state = :seekchar
            end
        end
    end
    CharWidths
end
CharWidths=parsesfd("unifont-$universion.sfd", CharWidths)
CharWidths=parsesfd("unifont_upper-$universion.sfd", CharWidths)

#############################################################################
# Widths from UAX #11: East Asian Width
#   .. these take precedence over the Unifont width for all codepoints
#      listed explicitly as wide/full/narrow/half-width

isfile("EastAsianWidth.txt") || download("http://www.unicode.org/Public/UNIDATA/EastAsianWidth.txt", "EastAsianWidth.txt")
for line in readlines(open("EastAsianWidth.txt"))
    #Strip comments
    line[1] == '#' && continue
    precomment = split(line, '#')[1]
    #Parse code point range and width code
    tokens = split(precomment, ';')
    length(tokens) >= 2 || continue
    charrange = tokens[1]
    width = strip(tokens[2])
    #Parse code point range into Julia UnitRange
    rangetokens = split(charrange, "..")
    charstart = uint32("0x"*rangetokens[1])
    charend = uint32("0x"*rangetokens[length(rangetokens)>1 ? 2 : 1])

    #Assign widths
    for c in charstart:charend
        if width=="W" || width=="F" # wide or full
            CharWidths[c]=2
        elseif width=="Na"|| width=="H" # narrow or half
            CharWidths[c]=1
        end
    end
end

#############################################################################
# A few exceptions to the above cases, found by manual comparison
# to other wcwidth functions and similar checks.

# Use ../libutf8proc for category codes, rather than the one in Julia,
# to minimize bootstrapping complexity when a new version of Unicode comes out.
function catcode(c)
    uint(c) > 0x10FFFF && return 0x0000 # see utf8proc_get_property docs
    return unsafe_load(ccall((:utf8proc_get_property,"../libutf8proc"), Ptr{UInt16}, (Int32,), c))
end

# use Base.UTF8proc module to get category codes constants, since
# we aren't goint to change these in utf8proc.
import Base.UTF8proc

for c in keys(CharWidths)
    cat = catcode(c)

    # make sure format control character (category Cf) have width 0,
    # except for the Arabic characters 0x06xx (see unicode std 6.2, sec. 8.2)
    if cat==UTF8proc.UTF8PROC_CATEGORY_CF && c ∉ [0x0601,0x0602,0x0603,0x06dd]
        CharWidths[c]=0
    end

    # Unifont has nonzero width for a number of non-spacing combining
    # characters, e.g. (in 7.0.06): f84,17b4,17b5,180b,180d,2d7f, and
    # the variation selectors
    if cat==UTF8proc.UTF8PROC_CATEGORY_MN
        CharWidths[c]=0
    end

    # We also assign width of zero to unassigned and private-use
    # codepoints (Unifont includes ConScript Unicode Registry PUA fonts,
    # but since these are nonstandard it seems questionable to recognize them).
    if cat==UTF8proc.UTF8PROC_CATEGORY_CO || cat==UTF8proc.UTF8PROC_CATEGORY_CN
        CharWidths[c]=0
    end
    
    # for some reason, Unifont has width-2 glyphs for ASCII control chars
    if cat==UTF8proc.UTF8PROC_CATEGORY_CC
        CharWidths[c]=0
    end
end

#By definition, should have zero width (on the same line)
#0x002028 ' ' category: Zl name: LINE SEPARATOR/
#0x002029 ' ' category: Zp name: PARAGRAPH SEPARATOR/
CharWidths[0x2028]=0
CharWidths[0x2029]=0

#By definition, should be narrow = width of 1 en space
#0x00202f ' ' category: Zs name: NARROW NO-BREAK SPACE/
CharWidths[0x202f]=1

#By definition, should be wide = width of 1 em space
#0x002001 ' ' category: Zs name: EM QUAD/
#0x002003 ' ' category: Zs name: EM SPACE/
CharWidths[0x2001]=2
CharWidths[0x2003]=2

#############################################################################
# Output (to a file or pipe) for processing by data_generator.rb
# ... don't bother to output zero widths since that will be the default.

firstc = 0x000000
lastv = 0
uhex(c) = uppercase(hex(c,4))
for c in 0x0000:0x110000
    v = get(CharWidths, c, 0)
    if v != lastv || c == 0x110000
        v < 4 || error("invalid charwidth $v for $c")
        if firstc+1 < c
            println(uhex(firstc), "..", uhex(c-1), "; ", lastv)
        else
            println(uhex(firstc), "; ", lastv)
        end
        firstc = c
        lastv = v
    end
end
