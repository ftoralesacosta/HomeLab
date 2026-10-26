#!/usr/bin/env python3
"""Generic patcher for OpenWrt/Linux sfp.ko (aarch64, ELF64 LE):
repoint the HALNy "HL-GSFP" quirk entry (fixup = ignore TX_FAULT + LOS) so it matches
vendor "OEM" / part "XPON-Stick" (= suffix of the existing "HSGQ-XPON-Stick" string).
usage: sfp_patch2.py sfp.ko.orig sfp.ko.patched"""
import struct, sys
src, dst = sys.argv[1], sys.argv[2]
f = bytearray(open(src, "rb").read())
e_shoff = struct.unpack_from("<Q", f, 0x28)[0]
e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", f, 0x3A)
secs = []
for i in range(e_shnum):
    o = e_shoff + i * e_shentsize
    name, typ, flags, addr, off, size, link, info, align, entsize = struct.unpack_from("<IIQQQQIIQQ", f, o)
    secs.append(dict(name=name, off=off, size=size, link=link, info=info))
sh = secs[e_shstrndx]
for s in secs:
    o = sh["off"] + s["name"]; s["n"] = f[o:f.index(b"\0", o)].decode()
idx = {s["n"]: i for i, s in enumerate(secs)}
symtab = secs[idx[".symtab"]]; strtab = secs[symtab["link"]]
def sym(i):
    o = symtab["off"] + i * 24
    st_name, st_info, st_other, st_shndx, st_value, st_size = struct.unpack_from("<IBBHQQ", f, o)
    return st_shndx, st_value
strsecs = {i for i, s in enumerate(secs) if s["n"].startswith(".rodata.str")}
rela = secs[idx[".rela.rodata"]]
rows = {}  # r_offset -> (fileoff, info, addend, string or None)
for k in range(rela["size"] // 24):
    o = rela["off"] + k * 24
    r_off, r_info, r_add = struct.unpack_from("<QQq", f, o)
    shndx, val = sym(r_info >> 32)
    s = None
    if shndx in strsecs:
        so = secs[shndx]["off"] + val + r_add
        s = f[so:f.index(b"\0", so)].decode(errors="replace")
    rows[r_off] = (o, r_info, r_add, s)
def find_entry(vendor, part):
    for off, (o, info, add, s) in rows.items():
        if s == vendor and rows.get(off + 8, (0, 0, 0, None))[3] == part:
            return off
v_halny = find_entry("HALNy", "HL-GSFP")
v_hsgq = find_entry("HSGQ", "HSGQ-XPON-Stick")
oem = next(off for off, r in rows.items() if r[3] == "OEM")
assert v_halny is not None and v_hsgq is not None, ("entries not found", v_halny, v_hsgq)
print("HALNy entry @rodata+%#x, HSGQ entry @rodata+%#x, OEM string reloc @rodata+%#x" % (v_halny, v_hsgq, oem))
fix = rows.get(v_halny + 0x18)
print("HALNy fixup reloc:", fix and (hex(fix[2])), "(should be a .text function: ignore LOS+TX_FAULT)")
# vendor -> "OEM"
o, info, add, _ = rows[v_halny]; _, oinfo, oadd, _ = rows[oem]
struct.pack_into("<QQq", f, o, v_halny, oinfo, oadd)
# part -> "XPON-Stick" (HSGQ part string + 5)
o, info, add, _ = rows[v_halny + 8]; _, pinfo, padd, ps = rows[v_hsgq + 8]
assert ps == "HSGQ-XPON-Stick"
struct.pack_into("<QQq", f, o, v_halny + 8, pinfo, padd + 5)
open(dst, "wb").write(f)
print("patched ->", dst)
