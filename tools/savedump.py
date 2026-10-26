#!/usr/bin/env python3
"""Saves for quartus/snes_load v8: read the on-screen save dump back into a .sav, and put a .sav
into a game's .spc file so the core loads it before the boot (notes/snes-load.md, "Saves (v8)").

Usage:
  savedump.py decode IMAGE|VIDEO|DIR ... [-o OUT.sav] [--spc FILE.spc|DIR] [--check RAM.bin]
  savedump.py patch FILE.spc SAVE.sav [-o OUT.spc]     (SAVE.sav "-": take the save out)
  savedump.py info FILE.spc ...
  savedump.py extract FILE.spc OUT.sav                 (exit status 1 if the file has no save)
  savedump.py render SAVE.sav OUTPREFIX [--crc HEX] [--id HEX] [--size N]
  savedump.py selftest [--size N] [--seed S]

decode reads photos (JPEG, PNG, HEIC, PPM) or recordings (any video ffmpeg/OpenCV reads; every
5th frame is tried) of the dump the core shows on L+R+SELECT+X, any order, any number: each
page needs to be in at least one picture, and rows a picture got wrong are taken from another
picture of the same page (or rebuilt from the page's parity rows). It writes the save (the dump
size the core showed: the header's RAM size) to -o (default: <game CRC>.sav in the current
directory), and with --spc puts it into the .spc whose ROM CRC-32 is the dumped game's (a file,
or every .spc under a directory, e.g. the SD card's SPC folder). --check compares with a RAM
image (the simulation's bsram.bin).

Screen format (quartus/common/ram_dump.sv has the same description): 1280x720, cells of 4 x 4
pixels; a white frame, 2 cells thick, around cells X 20-298, Y 14-165; a timing row (Y 17) and
column (X 23) of alternating cells; data cells X 24-295 (34 bytes a row, MSB first, white = 1),
Y 18-162 (145 rows): row 0 the header ("SNTD", format 1, page, page count, 4, dump size, game
ROM CRC-32, dump id, ROM_TYPE, RAM size byte), rows 1-128 the page's 4 KB (32 bytes each), each
of these rows ending in a CRC-16/CCITT-FALSE over page, row and the 32 bytes; rows 129-144 the
XOR of all 34 bytes of the rows r <= 128 with r mod 16 = row - 129.

Needs numpy and OpenCV (decode, render, selftest): `make savedump-venv` makes build/venv, which
this script uses by itself when the system Python has no cv2. HEIC photos need pillow-heif.
"""
import argparse
import glob
import os
import struct
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
VENV_PY = os.path.join(HERE, '..', 'build', 'venv', 'bin', 'python')

try:
    import numpy as np
    import cv2
except ImportError:
    if sys.argv[1:2] not in (['patch'], ['info'], ['extract']) and os.path.exists(VENV_PY) and \
            os.path.realpath(sys.prefix) != os.path.realpath(os.path.dirname(os.path.dirname(VENV_PY))):
        os.execv(VENV_PY, [VENV_PY, '-I'] + sys.argv)
    np = cv2 = None

sys.path.insert(0, HERE)
import rom2spc  # noqa: E402  (put_save, offsets)

CELL = 4                                  # pixels per cell on the screen
BOX = (20, 14, 299, 166)                  # frame's outer edge in cells: x0, y0, x1, y1 (exclusive)
BW, BH = BOX[2] - BOX[0], BOX[3] - BOX[1]  # 279 x 152 cells
DX, DY = 24 - BOX[0], 18 - BOX[1]          # data origin inside the box (4, 4)
ROWB, NROWS, DROWS, NPAR, PAGE = 34, 145, 128, 16, 4096
HDR_MAGIC = b'SNTD'


def crc16(data, c=0xFFFF):
    for b in data:
        c ^= b << 8
        for _ in range(8):
            c = ((c << 1) ^ 0x1021) & 0xFFFF if c & 0x8000 else (c << 1) & 0xFFFF
    return c


def row_crc(page, r, data32):
    return crc16(bytes([page & 0xFF, r & 0xFF]) + bytes(data32))


# ------------------------------------------------------------------------------- the pages
def make_rows(ram, page, npg, size, game_crc, dump_id, rom_type=0, ram_byte=0):
    """The 145 rows of 34 bytes the core shows for one page (ram: the whole RAM image)."""
    hdr = bytearray(32)
    hdr[0:4] = HDR_MAGIC
    hdr[4], hdr[5], hdr[6], hdr[7] = 1, page, npg, CELL
    struct.pack_into('<III', hdr, 8, size, game_crc, dump_id)
    hdr[20], hdr[21] = rom_type, ram_byte
    rows = []
    for r in range(DROWS + 1):
        if r == 0:
            d = bytes(hdr)
        else:
            a = page * PAGE + (r - 1) * 32
            d = bytes(ram[a + k] if a + k < size else 0 for k in range(32))
        rows.append(d + struct.pack('>H', row_crc(page, r, d)))
    for g in range(NPAR):
        p = bytearray(ROWB)
        for r in range(g, DROWS + 1, NPAR):
            p = bytearray(x ^ y for x, y in zip(p, rows[r]))
        rows.append(bytes(p))
    return rows


def render_page(rows, page, npg):
    """The 1280x720 screen (uint8 grey) for a page's rows, as ram_dump.sv draws it."""
    cells = np.zeros((180, 320), np.uint8)
    x0, y0, x1, y1 = BOX
    cells[y0:y1, x0:x1] = 255
    cells[y0 + 2:y1 - 2, x0 + 2:x1 - 2] = 0
    for x in range(23, 296):
        cells[17, x] = 255 if x & 1 else 0
    for y in range(17, 163):
        cells[y, 23] = 255 if y & 1 else 0
    bits = np.unpackbits(np.frombuffer(b''.join(rows), np.uint8)).reshape(NROWS, ROWB * 8)
    cells[18:18 + NROWS, 24:24 + ROWB * 8] = bits * 255
    for i in range(npg):
        cells[4:10, 20 + 8 * i:26 + 8 * i] = 255 if i == page else 0x50
    return np.kron(cells, np.ones((CELL, CELL), np.uint8))


# ------------------------------------------------------------------------------- reading
def load_images(path, every=5):
    """(name, grey image) for a photo, every `every`-th frame of a video, or the files in a dir."""
    if os.path.isdir(path):
        for f in sorted(glob.glob(os.path.join(path, '*'))):
            yield from load_images(f, every)
        return
    ext = os.path.splitext(path)[1].lower()
    if ext in ('.heic', '.heif'):
        from PIL import Image
        import pillow_heif
        pillow_heif.register_heif_opener()
        yield path, np.asarray(Image.open(path).convert('L'))
        return
    if ext in ('.mkv', '.mp4', '.avi', '.mov', '.webm', '.m4v'):
        cap = cv2.VideoCapture(path)
        n = 0
        while True:
            ok, fr = cap.read()
            if not ok:
                break
            if n % every == 0:
                yield f'{path}#{n}', cv2.cvtColor(fr, cv2.COLOR_BGR2GRAY)
            n += 1
        return
    img = cv2.imread(path, cv2.IMREAD_GRAYSCALE)
    if img is not None:
        yield path, img


def frame_candidates(gray):
    """Quadrilaterals that may be the frame's outer edge, largest first, in full-size pixels."""
    h, w = gray.shape
    s = min(1.0, 1600 / max(h, w))
    small = cv2.resize(gray, None, fx=s, fy=s, interpolation=cv2.INTER_AREA) if s < 1 else gray
    blur = cv2.GaussianBlur(small, (5, 5), 0)
    out = []
    bins = [cv2.threshold(blur, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)[1]]
    k = max(15, (min(small.shape) // 8) | 1)
    bins.append(cv2.adaptiveThreshold(blur, 255, cv2.ADAPTIVE_THRESH_MEAN_C, cv2.THRESH_BINARY, k, -10))
    for b in bins:
        cs, _ = cv2.findContours(b, cv2.RETR_LIST, cv2.CHAIN_APPROX_NONE)
        for c in cs:
            area = cv2.contourArea(c)
            if area < 0.04 * small.shape[0] * small.shape[1]:
                continue
            x, y, cw, ch = cv2.boundingRect(c)
            if x <= 1 or y <= 1 or x + cw >= small.shape[1] - 1 or y + ch >= small.shape[0] - 1:
                continue                                   # touches the picture's edge
            hull = cv2.convexHull(c)
            peri = cv2.arcLength(hull, True)
            q = cv2.approxPolyDP(hull, 0.02 * peri, True)
            if len(q) != 4:
                continue
            out.append((area, refine_quad(c, q.reshape(4, 2)) / s))
    out.sort(key=lambda t: -t[0])
    keep = []                                  # (Otsu and the adaptive threshold find the same ones)
    for _, q in out:
        if all(np.abs(q - k).max() > 0.004 * max(h, w) for k in keep):
            keep.append(q)
    return [edge_refine(gray, q) for q in keep]


def edge_refine(gray, q):
    """The frame's outer edge where the brightness crosses halfway from the dark margin to the
    white frame, measured across each side at 60 places (sub-pixel), a line fitted to each side."""
    q = order_corners(q.astype(np.float32))
    cs = float(np.sqrt(cv2.contourArea(q) / (BW * BH)))          # cell size in pixels
    g = cv2.GaussianBlur(gray.astype(np.float32), (0, 0), max(0.5, 0.15 * cs))
    s = np.arange(-1.6 * cs, 1.6 * cs, 0.25, dtype=np.float32)    # along the outward normal
    lines = []
    for i in range(4):
        a, b = q[i], q[(i + 1) % 4]
        d = (b - a) / np.hypot(*(b - a))
        n = np.array([d[1], -d[0]], np.float32)                   # outward (tl, tr, br, bl clockwise)
        t = np.linspace(0.06, 0.94, 60, dtype=np.float32)
        base = a[None, :] + t[:, None] * (b - a)[None, :]
        pts = base[:, None, :] + s[None, :, None] * n[None, None, :]
        prof = cv2.remap(g, pts[..., 0], pts[..., 1], cv2.INTER_LINEAR)
        found = []
        for k in range(len(t)):
            pr = prof[k]
            lo, hi = np.median(pr[-int(0.4 * cs / 0.25) - 1:]), pr[:len(s) // 2 + 2].max()
            if hi - lo < 20:
                continue
            mid = (lo + hi) / 2
            j = len(pr) - 1
            while j > 0 and pr[j] < mid:                             # from outside inwards
                j -= 1
            if j == len(pr) - 1 or j == 0:
                continue
            f = (pr[j] - mid) / (pr[j] - pr[j + 1])
            found.append(base[k] + (s[j] + f * 0.25) * n)
        if len(found) < 12:
            return q
        P = np.array(found, np.float32)
        for _ in range(2):                                            # fit, drop outliers, fit again
            vx, vy, x0, y0 = cv2.fitLine(P, cv2.DIST_L2, 0, 0.01, 0.01).ravel()
            dist = np.abs((P[:, 0] - x0) * vy - (P[:, 1] - y0) * vx)
            if (dist < 0.25 * cs).sum() >= 12:
                P = P[dist < 0.25 * cs]
        vx, vy, x0, y0 = cv2.fitLine(P, cv2.DIST_L2, 0, 0.01, 0.01).ravel()
        lines.append((np.array([x0, y0]), np.array([vx, vy])))
    out = []
    for i in range(4):
        (p1, d1), (p2, d2) = lines[i - 1], lines[i]
        A = np.array([d1, -d2]).T
        if abs(np.linalg.det(A)) < 1e-6:
            return q
        tt = np.linalg.solve(A, p2 - p1)
        out.append(p1 + tt[0] * d1)
    return np.array(out, np.float32)


def refine_quad(contour, q):
    """Corners from lines fitted to each side's contour points (more exact than the polygon)."""
    pts = contour.reshape(-1, 2).astype(np.float32)
    q = order_corners(q.astype(np.float32))
    lines = []
    for i in range(4):
        a, b = q[i], q[(i + 1) % 4]
        d = b - a
        L = np.hypot(*d)
        n = np.array([-d[1], d[0]]) / L
        t = ((pts - a) @ d) / (L * L)
        dist = np.abs((pts - a) @ n)
        sel = pts[(t > 0.1) & (t < 0.9) & (dist < max(3.0, 0.01 * L))]
        if len(sel) < 10:
            return q
        vx, vy, x0, y0 = cv2.fitLine(sel, cv2.DIST_HUBER, 0, 0.01, 0.01).ravel()
        lines.append((np.array([x0, y0]), np.array([vx, vy])))
    out = []
    for i in range(4):
        (p1, d1), (p2, d2) = lines[i - 1], lines[i]
        A = np.array([d1, -d2]).T
        if abs(np.linalg.det(A)) < 1e-6:
            return q
        t = np.linalg.solve(A, p2 - p1)
        out.append(p1 + t[0] * d1)
    return np.array(out, np.float32)


def order_corners(q):
    """tl, tr, br, bl (image orientation)."""
    c = q.mean(axis=0)
    ang = np.arctan2(q[:, 1] - c[1], q[:, 0] - c[0])
    q = q[np.argsort(ang)]                     # clockwise from about -135 degrees (tl first)
    i = np.argmin(q.sum(axis=1))
    return np.roll(q, -i, axis=0)


class Sampler:
    """The frame warped to PPC pixels a cell, cell means and the black/white threshold."""
    PPC = 8

    def __init__(self, gray, quad):
        p = self.PPC
        dst = np.array([[0, 0], [BW * p, 0], [BW * p, BH * p], [0, BH * p]], np.float32)
        H = cv2.getPerspectiveTransform(quad.astype(np.float32), dst)
        g = gray.astype(np.float32)
        scale = float(np.hypot(*(quad[1] - quad[0]))) / (BW * p)    # picture pixels per warp pixel
        if scale > 2:                                                # (less aliasing)
            g = cv2.GaussianBlur(g, (0, 0), 0.4 * scale)
        w = cv2.warpPerspective(g, H, (BW * p, BH * p), flags=cv2.INTER_LINEAR)
        # unsharp mask: a lone cell keeps its contrast against a blurry picture
        self.w = w + 1.0 * (w - cv2.GaussianBlur(w, (0, 0), 0.5 * p))
        self.thr, self.con = self.threshold_map()

    def means(self, dx=0.0, dy=0.0):
        """Mean of the middle half of every cell (BH x BW), shifted by (dx, dy) cells."""
        p = self.PPC
        M = np.float32([[1, 0, -dx * p], [0, 1, -dy * p]])
        w = cv2.warpAffine(self.w, M, (BW * p, BH * p), borderMode=cv2.BORDER_REPLICATE) if dx or dy else self.w
        c = w.reshape(BH, p, BW, p)[:, p // 4:p - p // 4, :, p // 4:p - p // 4]
        return c.mean(axis=(1, 3))

    def threshold_map(self):
        """Midway between white and black, each interpolated over the box from the frame (white,
        cells 0-1 from the edge) and the black gap inside it (cell 2) on all four sides."""
        m = self.means()
        wt, wb = m[0:2, :].mean(0), m[BH - 2:BH, :].mean(0)          # white top/bottom per column
        wl, wr = m[:, 0:2].mean(1), m[:, BW - 2:BW].mean(1)          # left/right per row
        bt, bb = m[2, :].copy(), m[BH - 3, :].copy()
        bl, br = m[:, 2].copy(), m[:, BW - 3].copy()
        for c in (bt, bb, bl, br):                                   # (their ends lie in the frame)
            c[:3], c[-3:] = c[3], c[-4]
        W = coons(wt, wb, wl, wr)
        B = coons(bt, bb, bl, br)
        return (W + B) / 2, np.maximum(W - B, 1.0)

    def bits(self, dx=0.0, dy=0.0, bias=0.0):
        """Cells above the threshold (+ bias x the local white-black contrast)."""
        m = self.means(dx, dy)
        return m > self.thr + bias * self.con


def coons(top, bottom, left, right):
    """Transfinite interpolation of four boundary curves (top/bottom over x, left/right over y)."""
    H, W = len(left), len(top)
    u = np.linspace(0, 1, W)[None, :]
    v = np.linspace(0, 1, H)[:, None]
    c00, c10, c01, c11 = top[0], top[-1], bottom[0], bottom[-1]
    return ((1 - v) * top[None, :] + v * bottom[None, :] + (1 - u) * left[:, None] + u * right[:, None]
            - ((1 - u) * (1 - v) * c00 + u * (1 - v) * c10 + (1 - u) * v * c01 + u * v * c11))


def timing_score(b):
    """Fraction of the timing row and column cells that are as they should be."""
    xs = np.arange(DX - 1, DX + ROWB * 8)
    ys = np.arange(DY - 1, DY + NROWS)
    ok = (b[DY - 1, xs] == ((xs + BOX[0]) & 1).astype(bool)).sum() + \
         (b[ys, DX - 1] == ((ys + BOX[1]) & 1).astype(bool)).sum()
    return ok / (len(xs) + len(ys))


def rows_from_bits(b):
    d = b[DY:DY + NROWS, DX:DX + ROWB * 8].astype(np.uint8)
    return [bytes(x) for x in np.packbits(d, axis=1)]


SHIFTS = [(0, 0)] + [(dx, dy) for dx in (-0.25, 0, 0.25) for dy in (-0.25, 0, 0.25) if dx or dy]
BIASES = (0.0, -0.15, 0.15)


def read_picture(gray):
    """Rows of the first frame candidate that looks like a dump: (header, page, {r: row}, parity
    {g: row}, score) or None."""
    for quad in frame_candidates(gray)[:6]:
        for rot in range(4):
            q = np.roll(quad, -rot, axis=0)
            try:
                s = Sampler(gray, q)
            except cv2.error:
                continue
            if timing_score(s.bits()) < 0.9:
                continue
            good, par, page, hdr = {}, {}, None, None
            for dx, dy in SHIFTS:
                for bias in BIASES:
                    rows = rows_from_bits(s.bits(dx, dy, bias))
                    h = rows[0]
                    if hdr is None and h[:4] == HDR_MAGIC and row_crc(h[5], 0, h[:32]) == int.from_bytes(h[32:34], 'big'):
                        hdr, page = h, h[5]
                    if page is None:
                        page = guess_page(rows)
                    for r in range(1, DROWS + 1):
                        if r not in good and row_crc(page, r, rows[r][:32]) == int.from_bytes(rows[r][32:34], 'big'):
                            good[r] = rows[r]
                    if (dx, dy, bias) == (0, 0, 0.0):
                        par = {g: rows[DROWS + 1 + g] for g in range(NPAR)}
                    if hdr is not None and len(good) == DROWS:
                        break
                if hdr is not None and len(good) == DROWS:
                    break
            if hdr is None and not good:
                continue
            if hdr is not None:
                good[0] = hdr
            return hdr, page, good, par
    return None


def guess_page(rows):
    best, bp = -1, 0
    for p in range(16):
        n = sum(row_crc(p, r, rows[r][:32]) == int.from_bytes(rows[r][32:34], 'big') for r in range(1, 20))
        if n > best:
            best, bp = n, p
    return bp


def rebuild(good, pars):
    """Rows missing from `good` (one per parity group) from the parity rows seen."""
    n = 0
    for g in range(NPAR):
        group = list(range(g, DROWS + 1, NPAR))
        miss = [r for r in group if r not in good]
        if len(miss) != 1:
            continue
        r = miss[0]
        for par in pars:
            x = bytearray(par[g])
            for q in group:
                if q != r:
                    x = bytearray(a ^ b for a, b in zip(x, good[q]))
            x = bytes(x)
            ok = (r == 0 and x[:4] == HDR_MAGIC and row_crc(x[5], 0, x[:32]) == int.from_bytes(x[32:34], 'big')) or \
                 (r > 0 and good.get(0) and row_crc(good[0][5], r, x[:32]) == int.from_bytes(x[32:34], 'big'))
            if ok:
                good[r] = x
                n += 1
                break
    return n


def cmd_decode(a):
    if cv2 is None:
        sys.exit('decode needs numpy and OpenCV: `make savedump-venv` (build/venv), then run this again')
    dumps = {}            # (game crc, dump id, size, npg) -> page -> {'good': {r: row}, 'pars': [..]}
    loose = []            # pictures whose header row was unreadable: (page, good, pars)
    for path in a.inputs:
        for name, gray in load_images(path):
            res = read_picture(gray)
            if res is None:
                if a.verbose:
                    print(f'{name}: no dump found')
                continue
            hdr, page, good, par = res
            if hdr is None:
                loose.append((page, good, par))
                print(f'{name}: page {page}?, header row unreadable, rows ok {len(good)}/{DROWS}')
                continue
            size, gcrc, did = struct.unpack_from('<III', hdr, 8)
            key = (gcrc, did, size, hdr[6])
            pg = dumps.setdefault(key, {}).setdefault(page, {'good': {}, 'pars': []})
            new = sum(r not in pg['good'] for r in good)
            pg['good'].update({r: v for r, v in good.items() if r not in pg['good']})
            pg['pars'].append(par)
            print(f'{name}: game {gcrc:08X} dump {did:08X} page {page + 1}/{hdr[6]}, rows ok {len(good) - 1}/{DROWS}'
                  f' ({new} new)')
    if not dumps:
        sys.exit('no dump found in the pictures')
    for page, good, par in loose:           # header unreadable: join a dump with that page if any
        for key, pages in dumps.items():
            if page in pages:
                pages[page]['good'].update({r: v for r, v in good.items() if r not in pages[page]['good']})
                pages[page]['pars'].append(par)
    key = max(dumps, key=lambda k: (len(dumps[k]), k[1]))
    if len(dumps) > 1:
        print('more than one dump in the pictures: ' + ', '.join(f'game {k[0]:08X} id {k[1]:08X} ({len(v)} pages)'
                                                                 for k, v in dumps.items()) + f'; using id {key[1]:08X}')
    gcrc, did, size, npg = key
    pages = dumps[key]
    data, missing = bytearray(), []
    for p in range(npg):
        pg = pages.get(p)
        if pg is None:
            missing.append(f'page {p + 1}: no picture')
            data += bytes(PAGE)
            continue
        n = rebuild(pg['good'], pg['pars'])
        bad = [r for r in range(1, DROWS + 1) if r not in pg['good']]
        if n:
            print(f'page {p + 1}: {n} row(s) rebuilt from parity')
        if bad:
            missing.append(f'page {p + 1}: rows {",".join(map(str, bad[:12]))}{"..." if len(bad) > 12 else ""}'
                           f' ({len(bad)}) unreadable')
        for r in range(1, DROWS + 1):
            data += pg['good'].get(r, bytes(ROWB))[:32]
    data = bytes(data[:size])
    if missing:
        print('INCOMPLETE: ' + '; '.join(missing) + '. Take another picture of those pages.')
    out = a.output or f'{gcrc:08X}.sav'
    if missing and not a.force:
        sys.exit(f'not written ({out}); --force writes it anyway with 0s for what is missing')
    open(out, 'wb').write(data)
    print(f'{out}: {len(data)} bytes, CRC-32 {zlib.crc32(data):08X} (game ROM CRC-32 {gcrc:08X}, dump id {did:08X})')
    if a.check:
        ram = open(a.check, 'rb').read()[:size]
        diff = sum(x != y for x, y in zip(ram, data))
        print(f'check against {a.check}: {"IDENTICAL" if ram == data else f"{diff} bytes differ"}')
        if ram != data:
            sys.exit(1)
    if a.spc:
        files = [a.spc] if os.path.isfile(a.spc) else sorted(glob.glob(os.path.join(a.spc, '**', '*.spc'), recursive=True))
        hits = [f for f in files if spc_info(f) and spc_info(f)['crc'] == gcrc]
        if not hits:
            sys.exit(f'no .spc with ROM CRC-32 {gcrc:08X} in {a.spc}')
        for f in hits:
            patch_file(f, data, f)
    if missing:
        sys.exit(1)


# ------------------------------------------------------------------------------- .spc files
def spc_info(path):
    with open(path, 'rb') as f:
        f.seek(rom2spc.INFO_OFF)
        blk = f.read(64)
    if len(blk) < 64 or blk[:8] != b'SNTROM01':
        return None
    rsize, crc = struct.unpack_from('<II', blk, 8)
    svs, svc = struct.unpack_from('<II', blk, 0x14)
    return {'size': rsize, 'crc': crc, 'save_size': svs, 'save_crc': svc,
            'name': blk[0x20:0x40].decode('ascii', 'replace').rstrip()}


def patch_file(path, sav, out):
    data = bytearray(open(path, 'rb').read())
    if data[rom2spc.INFO_OFF:rom2spc.INFO_OFF + 8] != b'SNTROM01':
        sys.exit(f'{path}: not a rom2spc.py file (no info block)')
    if len(sav) > rom2spc.SAVE_MAX:
        sys.exit(f'save is {len(sav)} bytes, at most {rom2spc.SAVE_MAX}')
    rom2spc.put_save(data, None, sav)
    tmp = out + '.tmp'
    open(tmp, 'wb').write(data)
    os.replace(tmp, out)
    print(f'{out}: ' + (f'save {len(sav)} bytes, CRC-32 {zlib.crc32(sav):08X}' if sav else 'no save'))


def cmd_patch(a):
    sav = b'' if a.save == '-' else open(a.save, 'rb').read()
    patch_file(a.spc, sav, a.output or a.spc)


def cmd_extract(a):
    i = spc_info(a.spc)
    if not i:
        sys.exit(f'{a.spc}: not a rom2spc.py file')
    if not i['save_size']:
        print(f'{a.spc}: no save')
        sys.exit(1)
    with open(a.spc, 'rb') as f:
        f.seek(rom2spc.SAVE_OFF)
        sav = f.read(i['save_size'])
    if zlib.crc32(sav) != i['save_crc']:
        sys.exit(f'{a.spc}: the save does not match its CRC-32')
    open(a.output, 'wb').write(sav)
    print(f'{a.output}: {len(sav)} bytes, CRC-32 {i["save_crc"]:08X}')


def cmd_info(a):
    for f in a.files:
        i = spc_info(f)
        if not i:
            print(f'{f}: not a rom2spc.py file')
            continue
        sv = f'save {i["save_size"]} bytes, CRC-32 {i["save_crc"]:08X}' if i['save_size'] else 'no save'
        print(f'{f}: "{i["name"]}", ROM {i["size"]} bytes, CRC-32 {i["crc"]:08X}, {sv}')


# ------------------------------------------------------------------------------- tests
def pages_for(ram, size, gcrc, did, rom_type=0, ram_byte=0):
    npg = (size + PAGE - 1) // PAGE
    return [render_page(make_rows(ram, p, npg, size, gcrc, did, rom_type, ram_byte), p, npg) for p in range(npg)]


def cmd_render(a):
    if cv2 is None:
        sys.exit('render needs numpy and OpenCV (make savedump-venv)')
    sav = open(a.save, 'rb').read()
    size = a.size or len(sav)
    ram = sav + bytes(max(0, size - len(sav)))
    for p, img in enumerate(pages_for(ram, size, a.crc, a.id)):
        cv2.imwrite(f'{a.prefix}{p:02d}.png', img)
    print(f'{(size + PAGE - 1) // PAGE} page(s): {a.prefix}NN.png')


def photo(img, rng, strength=1.0):
    """A screen image as a phone photo might show it: on a TV in a room, in perspective, a
    little rotated, blurred, with uneven light, noise and JPEG compression."""
    h, w = img.shape
    W, H = 4000, 3000
    scr = cv2.resize(img, (w * 2, h * 2), interpolation=cv2.INTER_NEAREST).astype(np.float32)
    scr = scr * 0.85 + 12                                     # the TV's black and white
    sw, sh = scr.shape[1], scr.shape[0]
    j = lambda: rng.uniform(-1, 1) * 180 * strength       # noqa: E731
    dst = np.float32([[400 + j(), 500 + j()], [3600 + j(), 450 + j()], [3650 + j(), 2400 + j()], [350 + j(), 2450 + j()]])
    M = cv2.getPerspectiveTransform(np.float32([[0, 0], [sw, 0], [sw, sh], [0, sh]]), dst)
    room = np.full((H, W), 90, np.float32)
    out = cv2.warpPerspective(scr, M, (W, H), dst=room, borderMode=cv2.BORDER_TRANSPARENT)
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    light = 0.75 + 0.35 * (xx / W) * strength + 0.1 * np.sin(yy / H * 3)
    out = out * light
    cx, cy = rng.uniform(1200, 2800), rng.uniform(900, 2100)
    out += 70 * strength * np.exp(-((xx - cx) ** 2 + (yy - cy) ** 2) / (2 * 260 ** 2))   # a glare spot
    out = cv2.GaussianBlur(out, (0, 0), 1.2 + strength)
    out += rng.normal(0, 6 * strength, out.shape)
    out = np.clip(out, 0, 255).astype(np.uint8)
    ok, jpg = cv2.imencode('.jpg', out, [cv2.IMWRITE_JPEG_QUALITY, 80])
    return cv2.imdecode(jpg, cv2.IMREAD_GRAYSCALE)


def cmd_selftest(a):
    if cv2 is None:
        sys.exit('selftest needs numpy and OpenCV (make savedump-venv)')
    rng = np.random.default_rng(a.seed)
    size = a.size
    ram = bytearray(rng.integers(0, 256, size, dtype=np.uint8).tobytes())
    ram[size // 2:size // 2 + 3000] = bytes(3000)                   # a run of 0s (unused save space)
    pages = pages_for(ram, size, 0x12345678, 0xABCD, 0x60, 5)
    tmp = a.dir
    os.makedirs(tmp, exist_ok=True)
    names = []
    for p, img in enumerate(pages):
        n = os.path.join(tmp, f'page{p:02d}.jpg')
        cv2.imwrite(n, photo(img, rng, a.strength))
        names.append(n)
    open(os.path.join(tmp, 'ram.bin'), 'wb').write(bytes(ram))
    print(f'{len(pages)} simulated photos in {tmp}')
    sys.argv = [sys.argv[0], 'decode'] + names + ['-o', os.path.join(tmp, 'out.sav'), '--check',
                                                   os.path.join(tmp, 'ram.bin')]
    main()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    sub = ap.add_subparsers(dest='cmd', required=True)
    d = sub.add_parser('decode', help='pictures of the dump -> .sav')
    d.add_argument('inputs', nargs='+')
    d.add_argument('-o', '--output')
    d.add_argument('--spc', help='put the save into the matching .spc (a file or a directory)')
    d.add_argument('--check', help='compare with a RAM image')
    d.add_argument('--force', action='store_true', help='write the .sav even if something is missing')
    d.add_argument('-v', '--verbose', action='store_true')
    p = sub.add_parser('patch', help='put a .sav into a .spc made by rom2spc.py')
    p.add_argument('spc')
    p.add_argument('save')
    p.add_argument('-o', '--output')
    i = sub.add_parser('info', help='show the info block of .spc files')
    i.add_argument('files', nargs='+')
    e = sub.add_parser('extract', help='write the save a .spc carries')
    e.add_argument('spc')
    e.add_argument('output')
    r = sub.add_parser('render', help='the dump screens of a .sav (PNG)')
    r.add_argument('save')
    r.add_argument('prefix')
    r.add_argument('--crc', type=lambda s: int(s, 16), default=0)
    r.add_argument('--id', type=lambda s: int(s, 16), default=0)
    r.add_argument('--size', type=int, default=0)
    t = sub.add_parser('selftest', help='render, "photograph" and decode random saves')
    t.add_argument('--size', type=int, default=8192)
    t.add_argument('--seed', type=int, default=1)
    t.add_argument('--strength', type=float, default=1.0)
    t.add_argument('--dir', default='/tmp/savedump-selftest')
    a = ap.parse_args()
    {'decode': cmd_decode, 'patch': cmd_patch, 'info': cmd_info, 'extract': cmd_extract, 'render': cmd_render,
     'selftest': cmd_selftest}[a.cmd](a)


if __name__ == '__main__':
    main()
