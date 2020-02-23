function check_error(err, error_msg)
    if err != 0
        error(error_msg * " with error: $(err)")
    end
end

const FREE_FONT_LIBRARY = FT_Library[C_NULL]

function ft_init()
    FREE_FONT_LIBRARY[1] != C_NULL && error("Freetype already initalized. init() called two times?")
    err = FT_Init_FreeType(FREE_FONT_LIBRARY)
    return err == 0
end

function ft_done()
    FREE_FONT_LIBRARY[1] == C_NULL && error("Library == CNULL. FreeTypeAbstraction.done() called before init(), or done called two times?")
    err = FT_Done_FreeType(FREE_FONT_LIBRARY[1])
    FREE_FONT_LIBRARY[1] = C_NULL
    return err == 0
end

function newface(facename, faceindex::Real=0, ftlib=FREE_FONT_LIBRARY)
    face = Ref{FT_Face}()
    err = FT_New_Face(ftlib[1], facename, Int32(faceindex), face)
    check_error(err, "Couldn't load font $facename")
    return face[]
end


struct FontExtent{T}
    vertical_bearing::Vec{2, T}
    horizontal_bearing::Vec{2, T}

    advance::Vec{2, T}
    scale::Vec{2, T}
end

BroadcastStyle(::Type{<: FontExtent}) = Style{FontExtent}()
BroadcastStyle(::Style{FontExtent}, x) = Style{FontExtent}()
BroadcastStyle(x, ::Style{FontExtent}) = Style{FontExtent}()

function broadcasted(op::Function, f::FontExtent, scaling::StaticVector)
    return FontExtent(
        op.(f.vertical_bearing, scaling[1]),
        op.(f.horizontal_bearing, scaling[2]),
        op.(f.advance, scaling),
        op.(f.scale, scaling),
    )
end

function broadcasted(op::Function, f::FontExtent)
    return FontExtent(
        op.(f.vertical_bearing),
        op.(f.horizontal_bearing),
        op.(f.advance),
        op.(f.scale),
    )
end

function broadcasted(op::Function, ::Type{T}, f::FontExtent) where T
    return FontExtent(
        map(x-> op(T, x), f.vertical_bearing),
        map(x-> op(T, x), f.horizontal_bearing),
        map(x-> op(T, x), f.advance),
        map(x-> op(T, x), f.scale),
    )
end

function FontExtent(fontmetric::FreeType.FT_Glyph_Metrics, scale::T = 64.0) where T <: AbstractFloat
    return FontExtent(
        Vec{2, T}(fontmetric.vertBearingX, fontmetric.vertBearingY) ./ scale,
        Vec{2, T}(fontmetric.horiBearingX, fontmetric.horiBearingY) ./ scale,
        Vec{2, T}(fontmetric.horiAdvance, fontmetric.vertAdvance) ./ scale,
        Vec{2, T}(fontmetric.width, fontmetric.height) ./ scale
    )
end

function ==(x::FontExtent, y::FontExtent)
    return (x.vertical_bearing == y.vertical_bearing &&
            x.horizontal_bearing == y.horizontal_bearing &&
            x.advance == y.advance &&
            x.scale == y.scale)
end

function FontExtent(fontmetric::FreeType.FT_Glyph_Metrics, scale::Integer)
    return FontExtent(
        div.(Vec{2, Int}(fontmetric.vertBearingX, fontmetric.vertBearingY), scale),
        div.(Vec{2, Int}(fontmetric.horiBearingX, fontmetric.horiBearingY), scale),
        div.(Vec{2, Int}(fontmetric.horiAdvance, fontmetric.vertAdvance), scale),
        div.(Vec{2, Int}(fontmetric.width, fontmetric.height), scale)
    )
end

function bearing(extent::FontExtent)
    return Vec2f0(extent.horizontal_bearing[1],
                  -(extent.scale[2] - extent.horizontal_bearing[2]))
end

function safe_free(face)
    ptr = getfield(face, :ft_ptr)
    if ptr != C_NULL && FREE_FONT_LIBRARY[1] != C_NULL
        FT_Done_Face(face)
    end
end

function boundingbox(extent::FontExtent)
    mini = bearing(extent)
    return Rect2D(mini, Vec2f0(extent.scale))
end

mutable struct FTFont
    ft_ptr::FreeType.FT_Face
    current_pixelsize::Base.RefValue{Int}
    use_cache::Bool
    cache::Dict{Tuple{Int, Char}, FontExtent{Float32}}
    function FTFont(ft_ptr::FreeType.FT_Face, pixel_size::Int=64, use_cache::Bool=true)
        cache = Dict{Tuple{Int, Char}, FontExtent{Float32}}()
        face = new(ft_ptr, Ref(pixel_size), use_cache, cache)
        finalizer(safe_free, face)
        FT_Set_Pixel_Sizes(face, pixel_size, 0);
        return face
    end
end

use_cache(face::FTFont) = getfield(face, :use_cache)
get_cache(face::FTFont) = getfield(face, :cache)

function FTFont(path::String)
    return FTFont(newface(path))
end

# C interop
function Base.cconvert(::Type{FreeType.FT_Face}, font::FTFont)
    return font
end

function Base.unsafe_convert(::Type{FreeType.FT_Face}, font::FTFont)
    return getfield(font, :ft_ptr)
end

function Base.propertynames(font::FTFont)
    return fieldnames(FreeType.FT_FaceRec)
end

function Base.getproperty(font::FTFont, fieldname::Symbol)
    fontrect = unsafe_load(getfield(font, :ft_ptr))
    field = getfield(fontrect, fieldname)
    if field isa Ptr{FT_String}
        field == C_NULL && return ""
        return unsafe_string(field)
    # Some fields segfault with unsafe_load...Lets find out which another day :D
    elseif field isa Ptr{FreeType.LibFreeType.FT_GlyphSlotRec}
        return unsafe_load(field)
    else
        return field
    end
end

get_pixelsize(face::FTFont) = getfield(face, :current_pixelsize)[]

function set_pixelsize(face::FTFont, size::Integer)
    get_pixelsize(face) == size && return size
    err = FT_Set_Pixel_Sizes(face, size, size)
    check_error(err, "Couldn't set pixelsize")
    getfield(face, :current_pixelsize)[] = size
    return size
end

function kerning(c1::Char, c2::Char, face::FTFont)
    i1 = FT_Get_Char_Index(face, c1)
    i2 = FT_Get_Char_Index(face, c2)
    kerning2d = Ref{FreeType.FT_Vector}()
    err = FT_Get_Kerning(face, i1, i2, FreeType.FT_KERNING_DEFAULT, kerning2d)
    # Can error if font has no kerning! Since that's somewhat expected, we just return 0
    err != 0 && return Vec2f0(0)
    # 64 since metrics are in 1/64 units (units to 26.6 fractional pixels)
    divisor = 64
    return Vec2f0(kerning2d[].x / divisor, kerning2d[].y / divisor)
end

function loadchar(face::FTFont, c::Char)
    err = FT_Load_Char(face, c, FT_LOAD_RENDER)
    check_error(err, "Could not load char to render.")
end

function get_extent(face::FTFont, char::Char)
    if use_cache(face)
        get!(get_cache(face), (get_pixelsize(face), char)) do
            return internal_get_extent(face, char)
        end
    else
        return internal_get_extent(face, char)
    end
end

function internal_get_extent(face::FTFont, char::Char)
    err = FT_Load_Char(face, char, FT_LOAD_DEFAULT)
    check_error(err, "Could not load char to get extend.")
    metrics = face.glyph.metrics
    # 64 since metrics are in 1/64 units (units to 26.6 fractional pixels)
    return FontExtent(metrics, Float32(64))
end
