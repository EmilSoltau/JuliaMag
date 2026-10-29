# A small read-only reader of Microsoft compound files (MS-CFB, also called
# OLE2 or structured storage). It reads one stream by name, enough for the
# `ipj` stream of a Geosoft `.grd.gi` file (research section 5).
#
# The layout, in short:
# - A 512-byte header, then sectors of 512 or 4096 bytes. Sector `n` starts at
#   byte `(n + 1) * sector size`.
# - The FAT has one 32-bit entry per sector: the next sector of the same chain.
#   The header lists the first 109 FAT sectors; more are listed in DIFAT sectors.
# - The directory is a chain of 128-byte entries. Entry 0 is the root. A
#   storage keeps its children in a tree of left and right siblings.
# - Streams shorter than the cutoff (4096 bytes) live in the mini stream, in
#   64-byte mini sectors chained by the mini FAT. The mini stream is the chain
#   of the root entry.
#
# The file is not trusted. Every sector number, chain length and size is
# checked against the file, and a damaged file throws `GridError`.

"The first 8 bytes of every compound file."
const CFB_MAGIC = UInt8[0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1]
"Sector numbers above this one are markers: end of chain, free, FAT and DIFAT sectors."
const CFB_MAX_SECTOR = 0xfffffffa
const CFB_END_OF_CHAIN = 0xfffffffe
const CFB_FREE = 0xffffffff

"An open compound file: its sector size, size and FAT."
struct CfbFile
    io::IO
    name::String
    size::Int
    sector::Int
    mini_sector::Int
    mini_cutoff::Int
    version::Int
    "The first sector of the directory and of the mini FAT."
    dir_start::UInt32
    minifat_start::UInt32
    fat::Vector{UInt32}
end

cfb_u16(b::Vector{UInt8}, off::Integer) = Int(ltoh(only(reinterpret(UInt16, b[off + 1:off + 2]))))
cfb_u32(b::Vector{UInt8}, off::Integer) = ltoh(only(reinterpret(UInt32, b[off + 1:off + 4])))

"The number of whole or partial sectors after the header."
cfb_sectors(f::CfbFile)::Int = cld(f.size - 512, f.sector)

"Read sector `n`. A last sector that the file cuts short is padded with zeros."
function cfb_sector(f::CfbFile, n::Integer)::Vector{UInt8}
    n <= CFB_MAX_SECTOR && 0 <= n < cfb_sectors(f) ||
        throw(GridError("$(f.name) points to sector $n, past the end of the file"))
    seek(f.io, (n + 1) * f.sector)
    b = read(f.io, f.sector)
    length(b) < f.sector && append!(b, zeros(UInt8, f.sector - length(b)))
    return b
end

"""
The sectors of the chain that starts at `start`, using `table` (the FAT or the
mini FAT). `limit` is the number of sectors there are. A chain longer than that
has a loop.
"""
function cfb_chain(f::CfbFile, table::Vector{UInt32}, start::UInt32, limit::Int, what::String)::Vector{Int}
    out = Int[]
    n = start
    while n != CFB_END_OF_CHAIN
        n <= CFB_MAX_SECTOR && n < min(length(table), limit) ||
            throw(GridError("the $what chain in $(f.name) points to sector $n, past the end of the file"))
        length(out) < limit || throw(GridError("the $what chain in $(f.name) has a loop"))
        push!(out, Int(n))
        n = table[n + 1]
    end
    return out
end

"Open the compound file on `io` and read its header and FAT."
function cfb_open(io::IO, name::String)::CfbFile
    size = Int(filesize(io))
    size >= 512 || throw(GridError("$name is $size bytes, shorter than the 512-byte header of a compound file"))
    seekstart(io)
    h = read(io, 512)
    h[1:8] == CFB_MAGIC || throw(GridError("$name is not a compound file (it does not start with d0 cf 11 e0)"))
    version = cfb_u16(h, 0x1a)
    shift = cfb_u16(h, 0x1e)
    mini_shift = cfb_u16(h, 0x20)
    version in (3, 4) && shift in (9, 12) && mini_shift == 6 ||
        throw(GridError("$name has a compound file header JuliaMag cannot read " *
                        "(version $version, sector shift $shift, mini sector shift $mini_shift)"))
    sector = 1 << shift
    nfat = Int(cfb_u32(h, 0x2c))
    ndifat = Int(cfb_u32(h, 0x48))
    sectors = cld(size - 512, sector)
    nfat <= sectors && ndifat <= sectors ||
        throw(GridError("$name says it has $nfat FAT sectors and $ndifat DIFAT sectors, more than the file holds"))
    f0 = CfbFile(io, name, size, sector, 64, Int(cfb_u32(h, 0x38)), version, cfb_u32(h, 0x30), cfb_u32(h, 0x3c),
                 UInt32[])
    # The FAT sectors: 109 in the header, the rest in a chain of DIFAT sectors.
    list = UInt32[cfb_u32(h, 0x4c + 4k) for k in 0:min(nfat, 109) - 1]
    next = cfb_u32(h, 0x44)
    per = sector ÷ 4 - 1
    for _ in 1:ndifat
        length(list) >= nfat && break
        b = cfb_sector(f0, next)
        for k in 0:per - 1
            length(list) < nfat && push!(list, cfb_u32(b, 4k))
        end
        next = cfb_u32(b, 4per)
    end
    length(list) == nfat || throw(GridError("$name lists $(length(list)) of its $nfat FAT sectors"))
    fat = UInt32[]
    for s in list
        b = cfb_sector(f0, s)
        append!(fat, ltoh.(reinterpret(UInt32, b)))
    end
    return CfbFile(io, name, size, sector, 64, f0.mini_cutoff, version, f0.dir_start, f0.minifat_start, fat)
end

"One directory entry: its name, type (1 storage, 2 stream, 5 root), tree links, start and size."
struct CfbEntry
    name::String
    kind::Int
    left::UInt32
    right::UInt32
    child::UInt32
    start::UInt32
    size::Int
end

"Read the directory of `f`."
function cfb_directory(f::CfbFile)::Vector{CfbEntry}
    entries = CfbEntry[]
    for s in cfb_chain(f, f.fat, f.dir_start, cfb_sectors(f), "directory")
        b = cfb_sector(f, s)
        for k in 0:(f.sector ÷ 128) - 1
            e = 128k
            n = min(cfb_u16(b, e + 64), 64)
            chars = reinterpret(UInt16, b[e + 1:e + 2(n ÷ 2)])
            name = transcode(String, ltoh.(chars))
            name = String(rstrip(name, '\0'))
            size = Int(cfb_u32(b, e + 120))
            # Version 3 files may hold anything in the upper 32 bits of the size.
            f.version == 4 && (size += Int(cfb_u32(b, e + 124)) << 32)
            push!(entries, CfbEntry(name, Int(b[e + 67]), cfb_u32(b, e + 68), cfb_u32(b, e + 72),
                                    cfb_u32(b, e + 76), cfb_u32(b, e + 116), size))
        end
    end
    isempty(entries) && throw(GridError("$(f.name) has no directory"))
    entries[1].kind == 5 || throw(GridError("the first directory entry of $(f.name) is not the root"))
    return entries
end

"""
The index of the child of the root named `name` (case is ignored), or `nothing`.
The children form a tree of left and right siblings; each entry is visited once.
"""
function cfb_find(f::CfbFile, entries::Vector{CfbEntry}, name::String)::Union{Nothing,Int}
    seen = falses(length(entries))
    todo = UInt32[entries[1].child]
    while !isempty(todo)
        k = pop!(todo)
        k == CFB_FREE && continue
        k < length(entries) || throw(GridError("the directory of $(f.name) points to entry $k, past its end"))
        seen[k + 1] && throw(GridError("the directory of $(f.name) has a loop"))
        seen[k + 1] = true
        e = entries[k + 1]
        lowercase(e.name) == lowercase(name) && return Int(k) + 1
        push!(todo, e.left, e.right)
    end
    return nothing
end

"Read `size` bytes from the sectors `chain` of size `sz`, where `read_sector(n)` gives sector `n`."
function cfb_gather(read_sector::F, chain::Vector{Int}, sz::Int, size::Int, f::CfbFile)::Vector{UInt8} where {F}
    length(chain) * sz >= size ||
        throw(GridError("a stream in $(f.name) is $size bytes, but its chain holds only $(length(chain) * sz)"))
    out = UInt8[]
    sizehint!(out, size)
    for n in chain
        length(out) >= size && break
        b = read_sector(n)
        append!(out, view(b, 1:min(sz, size - length(out))))
    end
    return out
end

"""
    read_cfb_stream(path, name)::Union{Nothing,Vector{UInt8}}

The bytes of the stream `name` (case is ignored) at the top level of the
Microsoft compound file `path`, or `nothing` when there is no such stream.
Throws `GridError` when the file is not a compound file or is damaged.
"""
function read_cfb_stream(path::AbstractString, name::AbstractString)::Union{Nothing,Vector{UInt8}}
    path = String(path)
    file = basename(path)
    return open(path) do io
        f = cfb_open(io, file)
        entries = cfb_directory(f)
        k = cfb_find(f, entries, String(name))
        k === nothing && return nothing
        e = entries[k]
        e.kind == 2 || return nothing
        e.size <= f.size || throw(GridError("the stream \"$name\" in $file is $(e.size) bytes, past the end of the file"))
        e.size == 0 && return UInt8[]
        sectors = cfb_sectors(f)
        if e.size >= f.mini_cutoff
            chain = cfb_chain(f, f.fat, e.start, sectors, "stream")
            return cfb_gather(n -> cfb_sector(f, n), chain, f.sector, e.size, f)
        end
        # A small stream: mini sectors inside the mini stream (the root's chain).
        root = entries[1]
        root.size <= f.size || throw(GridError("the mini stream of $file is $(root.size) bytes, past the end of the file"))
        mini = cfb_chain(f, f.fat, root.start, sectors, "mini stream")
        minifat = UInt32[]
        for s in cfb_chain(f, f.fat, f.minifat_start, sectors, "mini FAT")
            append!(minifat, ltoh.(reinterpret(UInt32, cfb_sector(f, s))))
        end
        per = f.sector ÷ f.mini_sector
        nmini = min(cld(root.size, f.mini_sector), length(mini) * per)
        chain = cfb_chain(f, minifat, e.start, nmini, "mini sector")
        return cfb_gather(chain, f.mini_sector, e.size, f) do n
            b = cfb_sector(f, mini[n ÷ per + 1])
            o = (n % per) * f.mini_sector
            b[o + 1:o + f.mini_sector]
        end
    end
end
