#!/usr/bin/env python3
"""Decode hwtest v5's bit images (display pages 29-35, gfx_render.sv mode 3) from photos or
simulation frames back into the 4 KB they show.

Usage: bitdump.py [--vote] [--out FILE] [--hex N] [--text W [--cells]]
                  [--corners x0,y0,x1,y1,x2,y2,x3,y3] IMAGE...

Each image is one frame of a bit-image page: 264 x 136 cells of 4 x 5 screen pixels at
x = 112, y = 36 of the 1280 x 720 picture: a white frame two cells thick, a black margin cell,
a timing ring (cell column + row even = white) and 256 x 128 data cells, one bit each (1 =
white), row r = bytes 32r .. 32r + 31, most significant bit left. For each image this prints
the CRC-32 (zlib, as the page header shows for the block), the number of timing-ring cells
read wrong (0 = the grid fits) and the black/white levels. Each block that decodes with at most
2 ring errors is shown once per CRC (several frames of one page give the same CRC: that's the
check); with --vote every bit is instead the majority of all such images (frames of the same
page only). --out FILE writes the 4096 bytes (FILE-<CRC>.bin per distinct block when there are
several images), --hex N prints the first N bytes, --text W prints them as text rows of W bytes (the player's
screen: 128; printable ASCII, '.' otherwise; --cells: only every other byte, the characters
of 2-byte cells). Images that are not a bit image (the ring reads
more than 40 % wrong at the first fit) are reported as such and skipped, so a whole video's
frames can be given (the frame search takes a few seconds per image).

Finding the picture (on a half-size copy): pixels brighter than their 51 x 51 neighbourhood,
eroded by 3 x 3 so that only thick lines remain (the frame is two cells, everything else one);
the connected region with the largest bounding box is the frame, and its four extreme points
(min/max of x + y and x - y) are the frame's outer corners, unless --corners gives them (top left, top right, bottom right, bottom left, in image pixels). A projective map
from the corners places every cell, with a radial lens distortion term about the image centre;
the corners and that term are then adjusted step by step while the timing ring agrees better.
Cells are read against a threshold halfway between the frame's and the margin's levels, each
fitted as a bilinear function of the position (uneven lighting). Needs ImageMagick's `convert`.
"""
import subprocess
import sys
import zlib
from collections import deque

import numpy as np

CW, CH = 264, 136          # cells, frame included
DX0, DY0 = 4, 4            # first data cell
NX, NY = 256, 128          # data cells


def load(path):
    pgm = subprocess.run(['convert', path, '-colorspace', 'Gray', '-depth', '8', 'pgm:-'],
                         check=True, capture_output=True).stdout
    # P5 header: magic, width, height, maxval, each followed by whitespace
    parts, pos = [], 0
    while len(parts) < 4:
        while pgm[pos:pos + 1].isspace():
            pos += 1
        if pgm[pos:pos + 1] == b'#':
            pos = pgm.index(b'\n', pos) + 1
            continue
        end = pos
        while not pgm[end:end + 1].isspace():
            end += 1
        parts.append(pgm[pos:end])
        pos = end
    pos += 1
    w, h = int(parts[1]), int(parts[2])
    return np.frombuffer(pgm[pos:pos + w * h], dtype=np.uint8).reshape(h, w).astype(np.float32)


def otsu(img):
    hist = np.bincount(img.astype(np.uint8).ravel(), minlength=256).astype(np.float64)
    p = hist / hist.sum()
    omega = np.cumsum(p)
    mu = np.cumsum(p * np.arange(256))
    with np.errstate(divide='ignore', invalid='ignore'):
        sb = (mu[-1] * omega - mu) ** 2 / (omega * (1 - omega))
    return float(np.nanargmax(sb))


def box_sum(a, r):
    """Sum over the (2r + 1)^2 window around each pixel (edges padded with edge values)."""
    p = np.pad(a.astype(np.float64), r, mode='edge')
    s = np.zeros((p.shape[0] + 1, p.shape[1] + 1))
    s[1:, 1:] = p.cumsum(0).cumsum(1)
    n = 2 * r + 1
    return s[n:, n:] - s[:-n, n:] - s[n:, :-n] + s[:-n, :-n]


def components(mask):
    """4-connected True regions (BFS), each as an array of (y, x)."""
    h, w = mask.shape
    seen = np.zeros_like(mask, dtype=bool)
    ys, xs = np.nonzero(mask)
    for y0, x0 in zip(ys, xs):
        if seen[y0, x0]:
            continue
        comp = []
        q = deque([(y0, x0)])
        seen[y0, x0] = True
        while q:
            y, x = q.popleft()
            comp.append((y, x))
            for yy, xx in ((y - 1, x), (y + 1, x), (y, x - 1), (y, x + 1)):
                if 0 <= yy < h and 0 <= xx < w and mask[yy, xx] and not seen[yy, xx]:
                    seen[yy, xx] = True
                    q.append((yy, xx))
        yield np.array(comp)


def find_corners(img):
    # bright against the neighbourhood (uneven lighting), then only what is thick: the frame is
    # two cells (8 x 10 screen pixels), data and ring cells are one
    small = img[::2, ::2]
    bright = small > box_sum(small, 25) / 51 ** 2
    bright &= small > otsu(small) * 0.5
    thick = box_sum(bright, 1) >= 9
    best, area = None, 0
    for comp in components(thick):
        y, x = comp[:, 0], comp[:, 1]
        a = (np.ptp(x) + 1) * (np.ptp(y) + 1)
        if a > area and len(comp) > 200:
            best, area = comp, a
    comp = best.astype(np.float64) * 2
    y, x = comp[:, 0], comp[:, 1]
    s, d = x + y, x - y
    # the erosion took ~1 small pixel (2 image pixels) off every edge
    return np.array([[x[s.argmin()] - 2, y[s.argmin()] - 2], [x[d.argmax()] + 3, y[d.argmax()] - 2],
                     [x[s.argmax()] + 3, y[s.argmax()] + 3], [x[d.argmin()] - 2, y[d.argmin()] + 3]])


def homography(src, dst):
    a = []
    for (u, v), (x, y) in zip(src, dst):
        a.append([u, v, 1, 0, 0, 0, -u * x, -v * x, -x])
        a.append([0, 0, 0, u, v, 1, -u * y, -v * y, -y])
    _, _, vt = np.linalg.svd(np.array(a))
    return vt[-1].reshape(3, 3)


def bilinear(img, x, y):
    h, w = img.shape
    x = np.clip(x, 0, w - 1.001)
    y = np.clip(y, 0, h - 1.001)
    x0, y0 = np.floor(x).astype(int), np.floor(y).astype(int)
    fx, fy = x - x0, y - y0
    return (img[y0, x0] * (1 - fx) * (1 - fy) + img[y0, x0 + 1] * fx * (1 - fy) +
            img[y0 + 1, x0] * (1 - fx) * fy + img[y0 + 1, x0 + 1] * fx * fy)


GU, GV = np.meshgrid(np.arange(CW) + 0.5, np.arange(CH) + 0.5)
EXPECT = np.full((CH, CW), -1, dtype=int)          # -1 data, 0 black, 1 white
EXPECT[:2, :] = EXPECT[-2:, :] = 1
EXPECT[:, :2] = EXPECT[:, -2:] = 1
EXPECT[2, 2:-2] = EXPECT[-3, 2:-2] = 0
EXPECT[2:-2, 2] = EXPECT[2:-2, -3] = 0
ring = np.zeros((CH, CW), dtype=bool)
ring[3, 3:-3] = ring[-4, 3:-3] = True
ring[3:-3, 3] = ring[3:-3, -4] = True
EXPECT[ring] = ((GU[ring].astype(int) + GV[ring].astype(int)) % 2 == 0).astype(int)
RING = ring
FRAME = EXPECT == 1
MARGIN = EXPECT == 0


def sample(img, corners, k=0.0):
    """Mean of 3 x 3 points in every cell; the grid from the projective map of the corners,
    then radial distortion k (x r^2, r = 1 at the image corner) about the image centre."""
    h, w = img.shape
    cx, cy, rn = w / 2, h / 2, (w * w + h * h) / 4
    # the corners are image positions: fit the projective map to where they were undistorted
    uc = corners.copy()
    if k:
        for _ in range(3):
            f = 1 + k * ((uc[:, 0] - cx) ** 2 + (uc[:, 1] - cy) ** 2) / rn
            uc = np.stack([cx + (corners[:, 0] - cx) / f, cy + (corners[:, 1] - cy) / f], 1)
    hm = homography([(0, 0), (CW, 0), (CW, CH), (0, CH)], uc)
    acc = np.zeros((CH, CW))
    for du in (-0.25, 0, 0.25):
        for dv in (-0.2, 0, 0.2):
            u, v = GU + du, GV + dv
            z = hm[2, 0] * u + hm[2, 1] * v + hm[2, 2]
            x = (hm[0, 0] * u + hm[0, 1] * v + hm[0, 2]) / z
            y = (hm[1, 0] * u + hm[1, 1] * v + hm[1, 2]) / z
            if k:
                f = 1 + k * ((x - cx) ** 2 + (y - cy) ** 2) / rn
                x, y = cx + (x - cx) * f, cy + (y - cy) * f
            acc += bilinear(img, x, y)
    return acc / 9


def level(vals, sel):
    """Least-squares a + b u + c v + d u v through the selected cells (lighting gradients)."""
    u, v = GU[sel] / CW, GV[sel] / CH
    m = np.stack([np.ones_like(u), u, v, u * v], 1)
    coef = np.linalg.lstsq(m, vals[sel], rcond=None)[0]
    uu, vv = GU / CW, GV / CH
    return coef[0] + coef[1] * uu + coef[2] * vv + coef[3] * uu * vv


def score(vals):
    white, black = level(vals, FRAME), level(vals, MARGIN)
    t = (white + black) / 2
    half = (white - black) / 2
    exp = EXPECT[RING]
    d = (vals - t)[RING]
    errors = int(((d > 0) != exp.astype(bool)).sum())
    soft = float(np.where(exp == 1, d, -d).clip(max=half[RING]).sum())
    return errors, soft, t, white.mean(), black.mean()


def decode(img, corners, force=False):
    corners = corners.astype(np.float64)
    best, k = min([(score(sample(img, corners, kk)), kk) for kk in (0.0, -0.025, 0.025, -0.05)],
                  key=lambda t: (t[0][0], -t[0][1]))
    if best[0] > 0.4 * RING.sum() and not force:
        return None                     # not a bit image (or nowhere near): skip the search
    for step in (2.0, 1.0, 0.5):
        improved = True
        while improved:
            improved = False
            cands = []
            for j in range(4):
                for dx, dy in ((step, 0), (-step, 0), (0, step), (0, -step)):
                    c = corners.copy()
                    c[j] += (dx, dy)
                    cands.append((c, k))
            cands += [(corners, k + step * 0.005), (corners, k - step * 0.005)]
            for c, kk in cands:
                sc = score(sample(img, c, kk))
                if (sc[0], -sc[1]) < (best[0], -best[1]):
                    best, corners, k, improved = sc, c, kk, True
    vals = sample(img, corners, k)
    errors, _, t, white, black = score(vals)
    bits = (vals > t)[DY0:DY0 + NY, DX0:DX0 + NX]
    return bits, errors, white, black, corners, k


def tobytes(bits):
    return np.packbits(bits.astype(np.uint8), axis=1).tobytes()


def show(data, hexn, textw, cells):
    if hexn:
        for i in range(0, min(hexn, len(data)), 32):
            print(f'{i:04X}: ' + ' '.join(data[i + k:i + k + 4].hex().upper() for k in range(0, 32, 4)))
    if textw:
        for i in range(0, len(data), textw):
            row = data[i:i + textw:2] if cells else data[i:i + textw]
            print(f'{i // textw:2d} |' + ''.join(chr(b) if 0x20 <= b < 0x7F else '.' for b in row) + '|')


def main():
    args = sys.argv[1:]
    out = hexn = corners = textw = None
    cells = vote = False
    paths = []
    while args:
        a = args.pop(0)
        if a == '--out':
            out = args.pop(0)
        elif a == '--hex':
            hexn = int(args.pop(0))
        elif a == '--text':
            textw = int(args.pop(0))
        elif a == '--cells':
            cells = True
        elif a == '--vote':
            vote = True
        elif a == '--corners':
            corners = np.array([float(v) for v in args.pop(0).split(',')]).reshape(4, 2)
        else:
            paths.append(a)
    if not paths:
        sys.exit(__doc__)
    good = []
    seen = {}
    for p in paths:
        img = load(p)
        try:
            c = corners if corners is not None else find_corners(img)
            res = decode(img, c, corners is not None)
        except (AttributeError, IndexError, np.linalg.LinAlgError):
            res = None
        if res is None:
            print(f'{p}: not a bit image')
            continue
        bits, errors, white, black, cfit, k = res
        data = tobytes(bits)
        crc = zlib.crc32(data)
        print(f'{p}: CRC {crc:08X}  ring errors {errors}/{int(RING.sum())}  '
              f'black {black:.0f} white {white:.0f}  distortion {k:+.3f}  corners ' +
              ' '.join(f'{x:.1f},{y:.1f}' for x, y in cfit), flush=True)
        if errors <= 2:
            good.append(bits)
            if not vote and crc not in seen:
                seen[crc] = data
                show(data, hexn, textw, cells)
                if out:
                    open(out if len(paths) == 1 else f'{out}-{crc:08X}.bin', 'wb').write(data)
    if not good:
        sys.exit('no image decoded with a clean timing ring')
    if vote:
        data = tobytes(np.mean(good, axis=0) > 0.5)
        print(f'majority of {len(good)}: CRC {zlib.crc32(data):08X}')
        show(data, hexn, textw, cells)
        if out:
            open(out, 'wb').write(data)


if __name__ == '__main__':
    main()
