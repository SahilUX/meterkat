"""QR codes for the terminal, so pairing doesn't need `qrencode`.

Byte mode only, versions 1-40, the highest error correction level that fits
the smallest version. Python 3.9+ standard library only. Follows Project
Nayuki's QR Code generator (MIT): https://www.nayuki.io/page/qr-code-generator-library
"""

import struct
import zlib

# Indexed by version (1-40); index 0 is unused.
ECC_CODEWORDS_PER_BLOCK = {
    "L": [-1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28,
          28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
    "M": [-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26,
          26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28],
    "Q": [-1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30,
          28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
    "H": [-1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28,
          30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
}
NUM_ERROR_CORRECTION_BLOCKS = {
    "L": [-1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8,
          8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25],
    "M": [-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16,
          17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49],
    "Q": [-1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20,
          23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68],
    "H": [-1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25,
          25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81],
}
FORMAT_BITS = {"L": 1, "M": 0, "Q": 3, "H": 2}
LEVELS = ["L", "M", "Q", "H"]  # lowest to highest

MASKS = [
    lambda x, y: (x + y) % 2 == 0,
    lambda x, y: y % 2 == 0,
    lambda x, y: x % 3 == 0,
    lambda x, y: (x + y) % 3 == 0,
    lambda x, y: (x // 3 + y // 2) % 2 == 0,
    lambda x, y: x * y % 2 + x * y % 3 == 0,
    lambda x, y: (x * y % 2 + x * y % 3) % 2 == 0,
    lambda x, y: ((x + y) % 2 + x * y % 3) % 2 == 0,
]

# Rule 3 of the mask penalty: a finder-like run with four light modules on one side.
FINDER_LIKE = ([True, False, True, True, True, False, True, False, False, False, False],
               [False, False, False, False, True, False, True, True, True, False, True])


def encode(text):
    """The QR code for `text` as rows of booleans (True is dark), without a quiet zone."""
    data = text.encode("utf-8")
    for version in range(1, 41):
        count_bits = 8 if version <= 9 else 16
        used = 4 + count_bits + 8 * len(data)
        if used <= _data_codewords(version, "L") * 8:
            break
    else:
        raise ValueError("too long for a QR code: %d bytes" % len(data))
    ecl = "L"
    for level in LEVELS[1:]:
        if used <= _data_codewords(version, level) * 8:
            ecl = level

    bits = []
    _append_bits(bits, 0b0100, 4)  # byte mode
    _append_bits(bits, len(data), count_bits)
    for b in data:
        _append_bits(bits, b, 8)
    capacity = _data_codewords(version, ecl) * 8
    _append_bits(bits, 0, min(4, capacity - len(bits)))
    _append_bits(bits, 0, -len(bits) % 8)
    pad = 0xEC
    while len(bits) < capacity:
        _append_bits(bits, pad, 8)
        pad ^= 0xEC ^ 0x11
    codewords = [int("".join("1" if b else "0" for b in bits[i:i + 8]), 2) for i in range(0, len(bits), 8)]

    return _QR(version, ecl, _add_ecc_and_interleave(codewords, version, ecl)).modules


def render(text, border=2):
    """`text` as a QR code in terminal half blocks: one character per module across, two per line
    down. Colors are set explicitly so it scans on dark and light terminal themes alike."""
    modules = encode(text)
    size = len(modules)

    def dark(x, y):
        return 0 <= x < size and 0 <= y < size and modules[y][x]

    lines = []
    for y in range(-border, size + border, 2):
        row = []
        for x in range(-border, size + border):
            top, bottom = dark(x, y), dark(x, y + 1)
            # Upper half block: foreground paints the top module, background the bottom one.
            row.append("\033[%d;%dm▀" % (30 if top else 97, 40 if bottom else 107))
        lines.append("".join(row) + "\033[0m")
    return "\n".join(lines)


def png(text, scale=8, border=2):
    """`text` as a black-and-white QR code PNG, `scale` pixels per module."""
    modules = encode(text)
    size = len(modules)
    width = (size + 2 * border) * scale
    rows = []
    for y in range(-border, size + border):
        row = bytes([0]) + b"".join(
            (b"\x00" if 0 <= x < size and 0 <= y < size and modules[y][x] else b"\xff") * scale
            for x in range(-border, size + border))
        rows.extend([row] * scale)

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    header = struct.pack(">IIBBBBB", width, width, 8, 0, 0, 0, 0)  # 8-bit grayscale
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(b"".join(rows)))
            + chunk(b"IEND", b""))


def _append_bits(bits, value, count):
    bits.extend((value >> i) & 1 == 1 for i in reversed(range(count)))


def _raw_data_modules(version):
    result = (16 * version + 128) * version + 64
    if version >= 2:
        num_align = version // 7 + 2
        result -= (25 * num_align - 10) * num_align - 55
        if version >= 7:
            result -= 36
    return result


def _data_codewords(version, ecl):
    return (_raw_data_modules(version) // 8
            - ECC_CODEWORDS_PER_BLOCK[ecl][version] * NUM_ERROR_CORRECTION_BLOCKS[ecl][version])


def _add_ecc_and_interleave(data, version, ecl):
    num_blocks = NUM_ERROR_CORRECTION_BLOCKS[ecl][version]
    ecc_len = ECC_CODEWORDS_PER_BLOCK[ecl][version]
    raw_codewords = _raw_data_modules(version) // 8
    num_short = num_blocks - raw_codewords % num_blocks
    short_len = raw_codewords // num_blocks
    divisor = _rs_divisor(ecc_len)
    blocks = []
    k = 0
    for i in range(num_blocks):
        block = data[k:k + short_len - ecc_len + (0 if i < num_short else 1)]
        k += len(block)
        ecc = _rs_remainder(block, divisor)
        if i < num_short:
            block.append(0)  # placeholder so every block has the same length; skipped below
        blocks.append(block + ecc)
    result = []
    for i in range(len(blocks[0])):
        for j, block in enumerate(blocks):
            if i != short_len - ecc_len or j >= num_short:
                result.append(block[i])
    return result


def _rs_multiply(x, y):
    z = 0
    for i in reversed(range(8)):
        z = (z << 1) ^ ((z >> 7) * 0x11D)
        z ^= ((y >> i) & 1) * x
    return z


def _rs_divisor(degree):
    result = [0] * (degree - 1) + [1]
    root = 1
    for _ in range(degree):
        for j in range(degree):
            result[j] = _rs_multiply(result[j], root)
            if j + 1 < degree:
                result[j] ^= result[j + 1]
        root = _rs_multiply(root, 0x02)
    return result


def _rs_remainder(data, divisor):
    result = [0] * len(divisor)
    for b in data:
        factor = b ^ result.pop(0)
        result.append(0)
        for i, coef in enumerate(divisor):
            result[i] ^= _rs_multiply(coef, factor)
    return result


class _QR:
    def __init__(self, version, ecl, codewords):
        self.version = version
        self.ecl = ecl
        self.size = version * 4 + 17
        self.modules = [[False] * self.size for _ in range(self.size)]
        self.is_function = [[False] * self.size for _ in range(self.size)]
        self._draw_function_patterns()
        self._draw_codewords(codewords)
        best = min(range(8), key=self._penalty_with_mask)
        self._apply_mask(best)
        self._draw_format_bits(best)

    def _set_function(self, x, y, dark):
        self.modules[y][x] = dark
        self.is_function[y][x] = True

    def _draw_function_patterns(self):
        size = self.size
        for i in range(size):
            self._set_function(6, i, i % 2 == 0)
            self._set_function(i, 6, i % 2 == 0)
        for cx, cy in ((3, 3), (size - 4, 3), (3, size - 4)):
            for dy in range(-4, 5):
                for dx in range(-4, 5):
                    x, y = cx + dx, cy + dy
                    if 0 <= x < size and 0 <= y < size:
                        self._set_function(x, y, max(abs(dx), abs(dy)) not in (2, 4))
        positions = self._alignment_positions()
        last = len(positions) - 1
        for i, ax in enumerate(positions):
            for j, ay in enumerate(positions):
                if (i, j) in ((0, 0), (0, last), (last, 0)):
                    continue  # overlaps a finder pattern
                for dy in range(-2, 3):
                    for dx in range(-2, 3):
                        self._set_function(ax + dx, ay + dy, max(abs(dx), abs(dy)) != 1)
        self._draw_format_bits(0)  # reserves the area; redrawn with the chosen mask
        self._draw_version()

    def _alignment_positions(self):
        if self.version == 1:
            return []
        num_align = self.version // 7 + 2
        step = (self.version * 8 + num_align * 3 + 5) // (num_align * 4 - 4) * 2
        return list(reversed([self.size - 7 - i * step for i in range(num_align - 1)] + [6]))

    def _draw_format_bits(self, mask):
        data = FORMAT_BITS[self.ecl] << 3 | mask
        rem = data
        for _ in range(10):
            rem = (rem << 1) ^ ((rem >> 9) * 0x537)
        bits = (data << 10 | rem) ^ 0x5412

        def bit(i):
            return (bits >> i) & 1 == 1

        size = self.size
        for i in range(6):
            self._set_function(8, i, bit(i))
        self._set_function(8, 7, bit(6))
        self._set_function(8, 8, bit(7))
        self._set_function(7, 8, bit(8))
        for i in range(9, 15):
            self._set_function(14 - i, 8, bit(i))
        for i in range(8):
            self._set_function(size - 1 - i, 8, bit(i))
        for i in range(8, 15):
            self._set_function(8, size - 15 + i, bit(i))
        self._set_function(8, size - 8, True)  # always dark

    def _draw_version(self):
        if self.version < 7:
            return
        rem = self.version
        for _ in range(12):
            rem = (rem << 1) ^ ((rem >> 11) * 0x1F25)
        bits = self.version << 12 | rem
        for i in range(18):
            dark = (bits >> i) & 1 == 1
            a, b = self.size - 11 + i % 3, i // 3
            self._set_function(a, b, dark)
            self._set_function(b, a, dark)

    def _draw_codewords(self, codewords):
        size = self.size
        total = len(codewords) * 8
        i = 0
        right = size - 1
        while right >= 1:
            if right == 6:
                right = 5  # skip the vertical timing pattern
            upward = (right + 1) & 2 == 0
            for vert in range(size):
                y = size - 1 - vert if upward else vert
                for x in (right, right - 1):
                    if not self.is_function[y][x] and i < total:
                        self.modules[y][x] = (codewords[i >> 3] >> (7 - (i & 7))) & 1 == 1
                        i += 1
            right -= 2

    def _apply_mask(self, mask):
        test = MASKS[mask]
        for y in range(self.size):
            for x in range(self.size):
                if not self.is_function[y][x] and test(x, y):
                    self.modules[y][x] = not self.modules[y][x]

    def _penalty_with_mask(self, mask):
        # XOR masks undo themselves, so try it, score it, and take it off again.
        self._apply_mask(mask)
        self._draw_format_bits(mask)
        score = self._penalty()
        self._apply_mask(mask)
        return score

    def _penalty(self):
        size = self.size
        m = self.modules
        lines = m + [[m[y][x] for y in range(size)] for x in range(size)]
        score = 0
        for line in lines:
            run = 1
            for i in range(1, size + 1):
                if i < size and line[i] == line[i - 1]:
                    run += 1
                    continue
                if run >= 5:
                    score += run - 2
                run = 1
            for i in range(size - 10):
                if line[i:i + 11] in FINDER_LIKE:
                    score += 40
        for y in range(size - 1):
            for x in range(size - 1):
                if m[y][x] == m[y][x + 1] == m[y + 1][x] == m[y + 1][x + 1]:
                    score += 3
        dark = sum(row.count(True) for row in m)
        total = size * size
        # 10 points for every 5% the dark share is away from 50%.
        score += ((abs(dark * 20 - total * 10) + total - 1) // total - 1) * 10
        return score
