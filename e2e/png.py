"""Minimal PNG reader (8-bit RGB/RGBA, non-interlaced) so screenshots can be sampled without Pillow."""
import struct
import zlib


class Image:
    def __init__(self, path):
        with open(path, "rb") as source:
            data = source.read()
        assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
        position, chunks = 8, []
        while position < len(data):
            length, kind = struct.unpack(">I4s", data[position:position + 8])
            chunks.append((kind, data[position + 8:position + 8 + length]))
            position += 12 + length
        header = dict(chunks)[b"IHDR"]
        self.width, self.height, depth, color, _, _, interlace = struct.unpack(">IIBBBBB", header)
        assert depth == 8 and color in (2, 6) and interlace == 0, (depth, color, interlace)
        self.channels = 3 if color == 2 else 4
        raw = zlib.decompress(b"".join(body for kind, body in chunks if kind == b"IDAT"))
        self.rows = self._unfilter(raw)

    def _unfilter(self, raw):
        stride = self.width * self.channels
        rows, previous = [], bytearray(stride)
        for y in range(self.height):
            start = y * (stride + 1)
            kind, line = raw[start], bytearray(raw[start + 1:start + 1 + stride])
            bpp = self.channels
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                up = previous[i]
                upper_left = previous[i - bpp] if i >= bpp else 0
                if kind == 1:
                    line[i] = (line[i] + left) & 255
                elif kind == 2:
                    line[i] = (line[i] + up) & 255
                elif kind == 3:
                    line[i] = (line[i] + (left + up) // 2) & 255
                elif kind == 4:
                    p = left + up - upper_left
                    pa, pb, pc = abs(p - left), abs(p - up), abs(p - upper_left)
                    pred = left if pa <= pb and pa <= pc else (up if pb <= pc else upper_left)
                    line[i] = (line[i] + pred) & 255
            rows.append(line)
            previous = line
        return rows

    def pixel(self, x, y):
        """(r, g, b) at pixel coordinates."""
        base = x * self.channels
        row = self.rows[y]
        return row[base], row[base + 1], row[base + 2]


def close(a, b, tolerance=6):
    return all(abs(x - y) <= tolerance for x, y in zip(a, b))


def hex_rgb(value):
    value = value.lstrip("#")
    return tuple(int(value[i:i + 2], 16) for i in (0, 2, 4))
