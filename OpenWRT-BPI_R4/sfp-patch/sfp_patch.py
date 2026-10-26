import struct, shutil
src, dst = "sfp.ko.orig", "sfp.ko.patched"
b = bytearray(open(src, "rb").read())
def rd(o): return struct.unpack_from("<QQq", b, o)
def wr(o, off, info, add): struct.pack_into("<QQq", b, o, off, info, add)
R52, R53, R74, R96 = 0x9490, 0x94a8, 0x96a0, 0x98b0   # HALNy vendor, HALNy part, HSGQ-XPON-Stick, OEM
o52, i52, a52 = rd(R52); o53, i53, a53 = rd(R53)
_, i74, a74 = rd(R74); _, i96, a96 = rd(R96)
wr(R52, o52, i96, a96)          # vendor -> "OEM"
wr(R53, o53, i74, a74 + 5)      # part   -> "XPON-Stick" (suffix of "HSGQ-XPON-Stick")
open(dst, "wb").write(b)
print("patched: vendor addend %#x -> %#x, part addend %#x -> %#x" % (a52, a96, a53, a74 + 5))
