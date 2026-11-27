import unittest

import qr


class QRTests(unittest.TestCase):
    def test_picks_the_smallest_version(self):
        self.assertEqual(len(qr.encode("hello")), 21)
        self.assertEqual(len(qr.encode("x" * 154)), 45)  # version 7 holds 154 bytes at level L
        self.assertEqual(len(qr.encode("x" * 155)), 49)

    def test_finder_patterns(self):
        m = qr.encode("meterkat://pair?token=abc")
        n = len(m)
        for x0, y0 in ((0, 0), (n - 7, 0), (0, n - 7)):
            self.assertTrue(all(m[y0][x0 + i] for i in range(7)))
            self.assertFalse(any(m[y0 + 1][x0 + i] for i in range(1, 6)))
            self.assertTrue(m[y0 + 3][x0 + 3])

    def test_png_header(self):
        data = qr.png("hi", scale=2, border=1)
        self.assertTrue(data.startswith(b"\x89PNG\r\n\x1a\n"))
        self.assertEqual(int.from_bytes(data[16:20], "big"), (21 + 2) * 2)

    def test_render_uses_half_blocks(self):
        lines = qr.render("hi", border=2).split("\n")
        self.assertEqual(len(lines), (21 + 4 + 1) // 2)


if __name__ == "__main__":
    unittest.main()
