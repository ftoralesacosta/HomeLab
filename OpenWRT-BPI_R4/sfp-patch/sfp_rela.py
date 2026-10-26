import struct, sys
f = open(sys.argv[1], "rb").read()
# ELF64 LE
e_shoff = struct.unpack_from("<Q", f, 0x28)[0]
e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", f, 0x3A)
secs = []
for i in range(e_shnum):
    o = e_shoff + i * e_shentsize
    name, typ, flags, addr, off, size, link, info, align, entsize = struct.unpack_from("<IIQQQQIIQQ", f, o)
    secs.append(dict(name=name, typ=typ, off=off, size=size, link=link, info=info, entsize=entsize))
shstr = secs[e_shstrndx]
def sname(s):
    o = shstr["off"] + s["name"]; return f[o:f.index(b"\0", o)].decode()
for s in secs: s["n"] = sname(s)
byname = {s["n"]: (i, s) for i, s in enumerate(secs)}
symtab = secs[byname[".symtab"][0]]
strtab = secs[symtab["link"]]
def sym(i):
    o = symtab["off"] + i * 24
    st_name, st_info, st_other, st_shndx, st_value, st_size = struct.unpack_from("<IBBHQQ", f, o)
    n = f[strtab["off"] + st_name: f.index(b"\0", strtab["off"] + st_name)].decode()
    return n, st_shndx, st_value
strsec_i, strsec = byname[".rodata.str1.8"]
def cstr(off):
    o = strsec["off"] + off; return f[o:f.index(b"\0", o)].decode(errors="replace")
rela = secs[byname[".rela.rodata"][0]]
rows = []
for k in range(rela["size"] // 24):
    o = rela["off"] + k * 24
    r_off, r_info, r_add = struct.unpack_from("<QQq", f, o)
    si = r_info >> 32; typ = r_info & 0xffffffff
    n, shndx, val = sym(si)
    tgt = secs[shndx]["n"] if shndx < len(secs) else str(shndx)
    desc = cstr(val + r_add) if shndx == strsec_i else "%s+%#x (%s)" % (tgt, val + r_add, n)
    rows.append((r_off, k, o, desc))
rows.sort()
want = sys.argv[2:] or []
for r_off, k, o, desc in rows:
    if not want or any(w in desc for w in want) or True:
        print("rodata+%#06x rela#%d fileoff=%#x : %s" % (r_off, k, o, desc))
