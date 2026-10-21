#!/usr/bin/env python3
"""Gate-level netlist around some seeds from a mistral-cv .bt decompile.

Usage:
  netlist.py file.bt [options] SEED...

SEED is a pin name (from --pins, default build/f23-pins.txt), a source port
(LAB.025.017.8:FFT1, GPIO.040.000.3:DATAIN.1, M10K...:DATAAOUT.3), a comb half
(LAB.029.012.5:T / :B, never the ALM's B input pin) or a sink port
(LAB.024.016:DATAIN.3). Input pins and source ports seed the forward walk; output
pins (their DATAOUT/OEIN drivers), sink ports and source ports seed the backward walk.

Options:
  --back N     levels (comb or register nodes) to walk backwards (default 3)
  --fwd N      levels to walk forwards (default 3)
  --names F    alias file: lines "SIGNAL NAME" (# comments); SIGNAL as printed
               (025.017.8.FFT1, M028.017.0.B) or as a port
  --pins F     pin list (tools/cvinfo pins output)
  --hmc F      HMC bypass table (tools/cvinfo hmc output, default build/hmc-bypass.txt)
  --raw        also print LUT masks and modes

Each LAB/MLAB ALM half is a comb node (`XXX.YYY.a.T` / `.B`, `M` prefix for MLABs),
each used FF a register node (`XXX.YYY.a.FFT0`); pins by name (`PIN.k` for GPIO
DATAIN.k when the pin has more than one, and always `PIN.3` for DATAIN.3, the IOE input
register path); other blocks by port. Top-bank pins reached through the hard memory
controller's bypass ports (HMC.011.045:IOINT*) are followed through to their GPIO ports
(--hmc table).
Register lines show D (with sync load/clear), clock, enable and async clear decoded
from the LAB control settings. As a library, Design.eval_comb/eval_arith/reg_next and
Sim simulate an extracted cluster (notes/pic-link.md, "Tool").

Bitstream conventions used (evidence in notes/pic-link.md, "Tool"):

- LUT: f(s) = ~M[j], j's bit k = ~s_k for a routed pin, 0 for an unrouted one (inputs
  and output inverted, unrouted pins read as 1). MLAB masks are bit-permuted.
- TMODE/BMODE = "<TA>_<TS>" / "<BA>_<BS>": mistral's ALM schematic muxes D/E0/TF into
  the top LUT's inputs TA, TS (and C/E1/BF into BA, BS). TF/BF are the register
  feedback lines, not the F pins: TF = FFT0 (T_FEEDBACK_SEL 0) or FFT1 (1), BF = FFB0 /
  FFB1 (B_FEEDBACK_SEL), taken at the FF output (before the TDFF/BDFF output muxes) and
  indexed like a routed input (index bit = ~Q). Printed as the FF's name.
- Top 5-LUT (low 32 bits): A0 B1 C2 TA3 F0:4; bottom 5-LUT (high 32): A0 B1 D2 BA3 F1:4.
  TA: E_0 -> E0, F_0 -> TF, D_x -> D. BA: E_1 -> E1, F_1 -> BF, C_x -> C.
- 6-LUT (TMODE D_E/D_F, BMODE C_E/C_F; the defaults): the output picks the top LUT
  (index bit 5 = 0) or the bottom LUT (bit 5 = 1) by its select, TS = E0 (D_E) or TF
  (D_F), BS = E1 (C_E) or BF (C_F); bit 4 = the output's own F pin (top F0, bottom F1).
- Arithmetic (ARITH_SEL ADDER): per half LUT0 = 16 bits (A B C|D TA|BA), LUT1 = next 16
  (A B C|D F), sum = LUT0 + ~LUT1 + carry-in (yosys MISTRAL_ALUT_ARITH); printed as
  `(LUT0) + (~LUT1) + cin`. Chain: ALM0 T, 0 B, 1 T ... 9 B; into ALM0 from the LAB
  above if TTO_DIS, into ALM5 from ALM4 if BTO_DIS; else carry-in 0 (assumed; Quartus
  counters that looked stuck under this were F_0 feedback counters, now explained).
- FF data: FFT0 TPKREG1, FFT1 TPKREG0, FFB0 BPKREG1, FFB1 BPKREG0 set = load from the
  E/F bypass (top E0, or F1 if TEF_SEL F; bottom E1, or F0 if BEF_SEL F), else from the
  half's LUT. Quartus sets these bits on unused FFs too.
- Clock/aclr groups: FFT0 and FFB1 use TCLK_SEL/TCLR_SEL, FFT1 and FFB0 BCLK_SEL/
  BCLR_SEL. Sync load and sync clear enables are per half (T*: FFT*, B*: FFB*).
- LAB clocks: mistral's two per-clock bits are swapped. The bit it calls CLKn_INV picks
  clkb (set) or clka; CLKn_SEL CLKB inverts. clka = CLKIN.0 or DATAIN.0 (CLKA_SEL DIN0,
  MLAB GIN2), clkb = CLKIN.1 or DATAIN.1 (CLKB_SEL DIN1, MLAB GIN3).
- LAB controls: enable n = DATAIN.(2,3,0)[n] if ENn_EN (default 1), active low if
  ENn_NINV (default 1; Quartus clears it for active-high enables). SLOAD = DATAIN.1
  (SLOAD_SEL DIN2: .2) ^ SLOAD_INV; SCLR = DATAIN.3 (SCLR_SEL DIN1: .1) ^ SCLR_INV; sync
  clear wins over sync load; enable gates both.
- FFT1L/FFB1L carry FFT1/FFB1 (or the comb output if [TB]DFF1L NLUT).
"""
import os
import re
import sys
from collections import defaultdict

sys.path.insert(0, __file__.rsplit('/', 1)[0])
import trace  # noqa: E402
from ffsrc import MLAB_PERMUTE  # noqa: E402

ALM_PINS = ('A', 'B', 'C', 'D', 'E0', 'E1', 'F0', 'F1')
FF_DFF = {'FFT0': 'TDFF0', 'FFT1': 'TDFF1', 'FFT1L': 'TDFF1L',
          'FFB0': 'BDFF0', 'FFB1': 'BDFF1', 'FFB1L': 'BDFF1L'}
FF_PK = {'FFT0': 'TPKREG1', 'FFT1': 'TPKREG0', 'FFB0': 'BPKREG1', 'FFB1': 'BPKREG0'}
FF_GRP = {'FFT0': 'T', 'FFB1': 'T', 'FFT1': 'B', 'FFB0': 'B'}
EN_DIN = {0: 2, 1: 3, 2: 0}
DEFAULT_HMC = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'build',
                           'hmc-bypass.txt')


# ------------------------------------------------------------------ boolean minimisation
def minimise(n, ones):
    """Quine-McCluskey + greedy cover. Returns list of (value, care) cubes."""
    if not ones:
        return []
    terms = {(m, (1 << n) - 1) for m in ones}
    primes = set()
    while terms:
        nxt, used = set(), set()
        tl = list(terms)
        for i, (v1, c1) in enumerate(tl):
            for v2, c2 in tl[i + 1:]:
                if c1 != c2:
                    continue
                d = (v1 ^ v2) & c1
                if d and not d & (d - 1):
                    nxt.add((v1 & ~d, c1 & ~d))
                    used.add((v1, c1))
                    used.add((v2, c2))
        primes |= terms - used
        terms = nxt
    cover, left = [], set(ones)
    plist = sorted(primes, key=lambda p: -bin(((1 << n) - 1) & ~p[1]).count('1'))
    while left:
        best = max(plist, key=lambda p: sum(1 for m in left if (m & p[1]) == p[0]))
        cover.append(best)
        left = {m for m in left if (m & best[1]) != best[0]}
    return cover


def sop(names, ones):
    n = len(names)
    full = 1 << n
    if not ones:
        return '0'
    if len(ones) == full:
        return '1'

    def fmt(cubes):
        out = []
        for v, c in cubes:
            lits = [('' if v >> k & 1 else '~') + names[k] for k in range(n) if c >> k & 1]
            out.append('&'.join(lits) if lits else '1')
        return out

    pos = fmt(minimise(n, ones))
    zeros = [m for m in range(full) if m not in set(ones)]
    neg = fmt(minimise(n, zeros))
    a = ' | '.join(pos)
    b = '~(' + ' | '.join(neg) + ')'
    if len(neg) == 1 and '&' not in neg[0] and '|' not in neg[0]:
        b = neg[0][1:] if neg[0].startswith('~') else '~' + neg[0]
    return a if len(a) <= len(b) else b


# ------------------------------------------------------------------ design database
class Design:
    # Switches for experiments; the defaults are the readings in the module docstring.
    FEEDBACK = True       # TF/BF = register feedback (False: the F pins, the old reading)
    TF_CROSS = False      # FEEDBACK=False only: F_0/F_1 TA/BA = the other half's F pin
    TS_F_CROSS = False    # FEEDBACK=False only: D_F/C_F select = the other half's F pin
    CLK_SWAP = True       # CLKn_INV picks clkb, CLKn_SEL CLKB inverts (False: mistral's names)

    def __init__(self, path, pinfile=None, names=None, hmc=None):
        self.drv, self.fan = trace.load(path)
        self.hmc_in = {}                  # HMC bypass input port -> GPIO DATAIN port
        self.hmc_out = set()              # HMC bypass output ports linked to a GPIO
        self.alm = defaultdict(dict)      # 'LAB.025.017.8' -> {key: val}
        self.lab = defaultdict(dict)      # 'LAB.025.017' -> {key: val}
        self.pinof = {}                   # GPIO port -> pin name (from comments)
        self.inv = {}
        for line in open(path):
            if line.startswith('s '):
                body = line[2:].split(' ; ')[0].split()
                key, val = body[0], body[1] if len(body) > 1 else ''
                m = re.match(r'((?:M?LAB)\.\d+\.\d+):(\w+)\.(\d+)$', key)
                if m:
                    self.alm[f'{m[1]}.{m[3]}'][m[2]] = val
                    continue
                m = re.match(r'((?:M?LAB)\.\d+\.\d+):(\w+)$', key)
                if m:
                    self.lab[m[1]][m[2]] = val
            elif line.startswith('r '):
                if ' ; ' in line:
                    body, pin = line.rstrip('\n').split(' ; ', 1)
                    for p in body[2:].split()[:2]:
                        if p.startswith('GPIO.'):
                            self.pinof[p] = pin.strip()
            elif line.startswith('i '):
                body = line[2:].split(' ; ')
                port, val = body[0].split()
                self.inv[port] = val
                # HMC bypass links also appear as comments on HMC inverter lines
                if line.startswith('i HMC') and len(body) == 3:
                    gpio = body[2].split()[-1]
                    if gpio.startswith('GPIO.'):
                        self.link_hmc(port, gpio, routed_only=False)
        # Top-bank pins: HMC bypass ports (IOINT*) <-> GPIO ports, for every route
        # (most bypass routes have no inverter line, so the comments above miss them)
        if hmc is None and os.path.exists(DEFAULT_HMC):
            hmc = DEFAULT_HMC
        if hmc:
            for line in open(hmc):
                f = line.split()
                if len(f) >= 2 and f[1].startswith('GPIO.'):
                    self.link_hmc(f[0], f[1])
        self.pins = {}
        if pinfile:
            for line in open(pinfile):
                f = line.split()
                if len(f) >= 2 and f[1].startswith('GPIO.'):
                    self.pins[f[0]] = f[1]
        self.alias = {}
        if names:
            for line in open(names):
                line = line.split('#')[0].split()
                if len(line) >= 2:
                    self.alias[line[0]] = line[1]
        self._deps = {}
        self.masks = {}
        for a, s in self.alm.items():
            if 'LUT_MASK' in s:
                hi, lo = (int(x, 16) for x in s['LUT_MASK'].split('.'))
                v = (hi << 32) | lo
                if a.startswith('MLAB'):
                    v = sum(((v >> MLAB_PERMUTE[i]) & 1) << i for i in range(64))
                self.masks[a] = v
            else:
                self.masks[a] = 0

    def link_hmc(self, port, gpio, routed_only=True):
        """Connect an HMC bypass port to its GPIO port (by default only if the HMC port
        is routed; an unrouted one becomes a leaf, i.e. a constant)."""
        if gpio.split(':')[1].startswith(('DATAOUT', 'OEIN')):
            if (port in self.drv or not routed_only) and gpio not in self.drv:
                self.drv[gpio] = port
                self.hmc_out.add(port)
        elif port in self.fan and port not in self.hmc_in:
            self.fan[gpio].append(port)
            self.hmc_in[port] = gpio

    # -- routing
    def source(self, port):
        src = trace.back(self.drv, port)[-1]
        while src in self.hmc_out and src in self.drv:   # GPIO <- HMC bypass <- fabric
            src = trace.back(self.drv, src)[-1]
        return self.hmc_in.get(src, src)  # fabric <- HMC bypass <- GPIO DATAIN

    def sinks(self, port):
        out = []
        for p in trace.fwd(self.fan, port):
            out += trace.fwd(self.fan, p) if p in self.hmc_in else [p]
        return sorted(out)

    def routed(self, port):
        return port in self.drv or (self.FEEDBACK and port.endswith((':TF', ':BF')))

    # -- naming
    def short(self, blk):
        m = re.match(r'(M?)LAB\.(\d+\.\d+\.\d+)$', blk)
        return (m[1] + m[2]) if m else blk

    def name(self, sig):
        """Name of a signal (a canonical source)."""
        if sig in self.alias:
            return self.alias[sig]
        if sig.startswith('GPIO.') and ':DATAIN' in sig:
            blk = sig.split(':')[0]
            pin = self.pinof.get(sig) or next((p for p, g in self.pins.items() if g == blk), None)
            if pin:
                suffix = self.other_datain_used(sig) or sig.endswith('.3')
                return pin + ('.' + sig[-1] if suffix else '')
        if sig.startswith('const'):
            return sig
        m = re.match(r'((?:M?LAB)\.\d+\.\d+\.\d+):(\w+)$', sig)
        if m:
            nm = f'{self.short(m[1])}.{m[2]}'
            return self.alias.get(nm, nm)
        return sig

    def other_datain_used(self, sig):
        base = sig[:-1]
        return any(base + str(k) in self.fan for k in range(4) if str(k) != sig[-1])

    def canon(self, src):
        """Canonical signal for a source port: comb halves as ALM.T/.B, regs as ALM:FFxx."""
        m = re.match(r'((?:M?LAB)\.\d+\.\d+\.\d+):(FF[TB][01]L?)$', src)
        if not m:
            return src
        alm, port = m[1], m[2]
        s = self.alm[alm]
        half = port[2]
        if s.get(FF_DFF[port]) == 'NLUT':
            return f'{alm}:{half}'
        if port.endswith('L'):
            return f'{alm}:FF{half}1'
        return f'{alm}:{port}'

    def feedback(self, alm, half):
        """Register on the half's feedback line (TF/BF): FF?0 or FF?1 by [TB]_FEEDBACK_SEL."""
        return f'{alm}:FF{half}{self.alm[alm].get(half + "_FEEDBACK_SEL", "0")}'

    def sig_of_pin(self, alm, pin):
        if pin in ('TF', 'BF') and self.FEEDBACK:
            return self.feedback(alm, pin[0])
        port = f'{alm}:{pin}'
        if port not in self.drv:
            return None
        return self.canon(self.source(port))

    # -- LUT evaluation
    def half_spec(self, alm, half):
        """(input pins, function(index assignment)->bit, kind) for an ALM half."""
        s = self.alm[alm]
        M = self.masks[alm]
        tm, bm = s.get('TMODE', 'D_E'), s.get('BMODE', 'C_E')
        if tm == 'RAM':
            return None
        if self.FEEDBACK:
            tf_t, tf_b = 'TF', 'BF'
        else:
            tf_t = 'F1' if self.TF_CROSS else 'F0'
            tf_b = 'F0' if self.TF_CROSS else 'F1'
        ta = {'E_0': 'E0', 'F_0': tf_t, 'D_E': 'D', 'D_F': 'D'}.get(tm, 'D')
        ba = {'E_1': 'E1', 'F_1': tf_b, 'C_E': 'C', 'C_F': 'C'}.get(bm, 'C')
        if s.get('ARITH_SEL') == 'ADDER':
            base = 0 if half == 'T' else 32
            cd = 'C' if half == 'T' else 'D'
            e, f = (ta, 'F0') if half == 'T' else (ba, 'F1')
            l0 = ([('A', 0), ('B', 1), (cd, 2), (e, 3)], base)
            l1 = ([('A', 0), ('B', 1), (cd, 2), (f, 3)], base + 16)
            return 'arith', (l0, l1)
        mode = tm if half == 'T' else bm
        own_f, cross_f = ('F0', 'F1') if half == 'T' else ('F1', 'F0')
        own_e = 'E0' if half == 'T' else 'E1'
        if mode in ('D_E', 'D_F', 'C_E', 'C_F'):
            f = own_f
            if mode.endswith('E'):
                e = own_e
            else:
                e = (tf_t if half == 'T' else tf_b) if (self.TS_F_CROSS or self.FEEDBACK) else own_f
            pins = sorted({'A', 'B', 'C', 'D', ta, ba, e, f})

            def idx(vals, e=e, f=f, ta=ta, ba=ba):   # vals: pin -> index bit value (0/1)
                hi = vals[e]
                j = vals['A'] | vals['B'] << 1 | vals[f] << 4 | hi << 5
                if hi:
                    j |= vals['D'] << 2 | vals[ba] << 3
                else:
                    j |= vals['C'] << 2 | vals[ta] << 3
                return j
            return 'lut6', (pins, idx, M)
        x3 = ta if half == 'T' else ba
        if half == 'T':
            pins, base = [('A', 0), ('B', 1), ('C', 2), (x3, 3), ('F0', 4)], 0
        else:
            pins, base = [('A', 0), ('B', 1), ('D', 2), (x3, 3), ('F1', 4)], 32

        def idx5(vals, pins=pins, base=base):
            return base + sum(vals[p] << b for p, b in pins)
        return 'lut5', ([p for p, _ in pins], idx5, M)

    def comb_function(self, alm, pins, idx, M):
        """Truth table of f over the routed pins that matter. Returns (sigs, ones)."""
        routed = [p for p in pins if self.routed(f'{alm}:{p}')]

        def f(assign):  # assign: pin -> signal value
            vals = {p: 0 for p in pins}
            for p in routed:
                vals[p] = 1 - assign[p]
            return 1 - (M >> idx(vals) & 1)
        # drop pins the function does not depend on
        deps = []
        for p in routed:
            others = [q for q in routed if q != p]
            dep = False
            for k in range(1 << len(others)):
                a = {q: k >> i & 1 for i, q in enumerate(others)}
                a[p] = 0
                v0 = f(a)
                a[p] = 1
                if f(a) != v0:
                    dep = True
                    break
            if dep:
                deps.append(p)
        ones = []
        for k in range(1 << len(deps)):
            a = {q: 1 for q in routed}
            a.update({q: k >> i & 1 for i, q in enumerate(deps)})
            if f(a):
                ones.append(k)
        return deps, ones

    def comb(self, alm, half):
        """-> (expression string, [input signals], kind)"""
        spec = self.half_spec(alm, half)
        if spec is None:
            ins = [self.sig_of_pin(alm, p) for p in ALM_PINS]
            ins = [x for x in ins if x]
            return 'mlab_ram(' + ', '.join(self.name(x) for x in ins) + ')', ins, 'ram'
        kind, data = spec
        if kind == 'arith':
            parts, ins = [], []
            for pins, base in data:
                pn = [p for p, _ in pins]

                def idx(vals, pins=pins, base=base):
                    return base + sum(vals[p] << b for p, b in pins)
                deps, ones = self.comb_function(alm, pn, idx, self.masks[alm])
                sigs = [self.sig_of_pin(alm, p) for p in deps]
                ins += sigs
                if base % 32:   # LUT1 enters the adder inverted (yosys alm_sim.v)
                    ones = [k for k in range(1 << len(sigs)) if k not in set(ones)]
                parts.append(sop([self.name(x) for x in sigs], ones))
            prev = f'cin({self.short(alm)}.{half})'
            return f'({parts[0]}) + ({parts[1]}) + {prev}', ins, 'arith'
        pins, idx, M = data
        deps, ones = self.comb_function(alm, pins, idx, M)
        sigs = [self.sig_of_pin(alm, p) for p in deps]
        return sop([self.name(x) for x in sigs], ones), sigs, kind

    def carry_in(self, alm, half):
        """Signal name of the carry into an arith half ('const0' at a chain start)."""
        lab, a = alm.rsplit('.', 1)
        a = int(a)
        if half == 'B':
            return f'cout:{alm}:T'
        if a == 5 and self.lab[lab].get('BTO_DIS') != '1':
            return 'const0'
        if a == 0:
            if self.lab[lab].get('TTO_DIS') != '1':
                return 'const0'
            kind, x, y = lab.split('.')
            for k in ('LAB', 'MLAB'):
                up = f'{k}.{x}.{int(y) + 1:03d}.9'
                if up in self.alm:
                    return f'cout:{up}:B'
            return 'const0'
        return f'cout:{lab}.{a - 1}:B'

    def eval_arith(self, alm, half, val):
        """(sum, carry-out) of an arith half: LUT0 + ~LUT1 + cin."""
        kind, (l0, l1) = self.half_spec(alm, half)
        bits = []
        for k, (pins, base) in enumerate((l0, l1)):
            pn = [p for p, _ in pins]

            def idx(vals, pins=pins, base=base):
                return base + sum(vals[p] << b for p, b in pins)
            key = (alm, half, k)
            if key not in self._deps:
                self._deps[key] = self.comb_function(alm, pn, idx, self.masks[alm])[0]
            vals = {p: 0 for p in pn}
            for p in self._deps[key]:
                vals[p] = 1 - val(self.sig_of_pin(alm, p))
            bits.append(1 - (self.masks[alm] >> idx(vals) & 1))
        c = self.carry_in(alm, half)
        cin = 0 if c == 'const0' else val(c)
        t = bits[0] + (1 - bits[1]) + cin
        return t & 1, t >> 1

    def eval_comb(self, alm, half, val):
        """Value of a comb half; val(signal) gives input signal values."""
        kind, data = self.half_spec(alm, half)
        if kind == 'arith':
            return self.eval_arith(alm, half, val)[0]
        pins, idx, M = data
        key = (alm, half)
        if key not in self._deps:
            self._deps[key] = self.comb_function(alm, pins, idx, M)[0]
        vals = {p: 0 for p in pins}    # pins the function ignores: any value
        for p in self._deps[key]:
            vals[p] = 1 - val(self.sig_of_pin(alm, p))
        return 1 - (M >> idx(vals) & 1)

    # -- registers
    def lab_ctl(self, lab, din):
        port = f'{lab}:DATAIN.{din}'
        return self.canon(self.source(port)) if port in self.drv else None

    def reg(self, alm, ff):
        """-> dict with d, clk, en, sload, sclr, aclr (signals or None) and text."""
        s = self.alm[alm]
        lab = alm.rsplit('.', 1)[0]
        L = self.lab[lab]
        half = ff[2]
        grp = FF_GRP[ff]
        r = {'ins': []}
        if half == 'T':
            sdpin = 'F1' if s.get('TEF_SEL') == 'F' else 'E0'
        else:
            sdpin = 'F0' if s.get('BEF_SEL') == 'F' else 'E1'
        sd = self.sig_of_pin(alm, sdpin)
        if s.get(FF_PK[ff]) == '1':
            r['d'] = self.name(sd) if sd else f'(bypass {sdpin} unrouted)'
            r['d_sig'] = sd or 'const1'
            if sd:
                r['ins'].append(sd)
        else:
            r['d'] = self.name(f'{alm}:{half}')
            r['d_sig'] = f'{alm}:{half}'
            r['ins'].append(f'{alm}:{half}')
        clk = s.get(grp + 'CLK_SEL')
        if not clk:
            r['clk'] = 'none'
        else:
            n = int(clk[-1])
            if self.CLK_SWAP:
                ab = 'CLKB' if L.get(f'CLK{n}_INV') == '1' else 'CLKA'
                cinv = L.get(f'CLK{n}_SEL') == 'CLKB'
            else:
                ab = L.get(f'CLK{n}_SEL', 'CLKA')
                cinv = L.get(f'CLK{n}_INV') == '1'
            if ab == 'CLKA':
                srcsel = L.get('CLKA_SEL', 'CIN0')
                port = {'CIN0': f'{lab}:CLKIN.0', 'DIN0': f'{lab}:DATAIN.0',
                        'GIN2': f'{lab}:DATAIN.0'}.get(srcsel, srcsel)
            else:
                srcsel = L.get('CLKB_SEL', 'CIN1')
                port = {'CIN1': f'{lab}:CLKIN.1', 'DIN1': f'{lab}:DATAIN.1',
                        'GIN3': f'{lab}:DATAIN.1'}.get(srcsel, srcsel)
            src = self.canon(self.source(port)) if port in self.drv else port
            if 'DATAIN' in port and src != port:
                r['ins'].append(src)
            r['clk_sig'], r['clk_inv'] = src, cinv
            r['clk'] = ('~' if cinv else '') + self.name(src) + f' [CLK{n}]'
            if L.get(f'EN{n}_EN', '1') == '1':
                e = self.lab_ctl(lab, EN_DIN[n])
                inv = L.get(f'EN{n}_NINV', '1') == '1'
                if e:
                    r['en'] = ('~' if inv else '') + self.name(e)
                    r['en_sig'] = (e, inv)
                    r['ins'].append(e)
                else:
                    r['en'] = f'{"~" if inv else ""}(DATAIN.{EN_DIN[n]} unrouted)'
        if s.get(half + 'SLOAD_EN') == '1':
            if L.get('SLOAD_EN', '1') == '0':
                r['sload'] = None
            else:
                din = 2 if L.get('SLOAD_SEL') == 'DIN2' else 1
                e = self.lab_ctl(lab, din)
                inv = L.get('SLOAD_INV') == '1'
                r['sload'] = ('~' if inv else '') + (self.name(e) if e else f'(DATAIN.{din} unrouted)')
                r['sdata'] = self.name(sd) if sd else f'({sdpin} unrouted)'
                r['sload_sig'] = (e or 'const1', inv, sd or 'const1')
                if e:
                    r['ins'].append(e)
                if sd:
                    r['ins'].append(sd)
        if s.get(half + 'SCLR_DIS') != '1' and L.get('SCLR_DIS') != '1':
            din = 1 if L.get('SCLR_SEL') == 'DIN1' else 3
            e = self.lab_ctl(lab, din)
            if e:
                r['sclr'] = ('~' if L.get('SCLR_INV') == '1' else '') + self.name(e)
                r['sclr_sig'] = (e, L.get('SCLR_INV') == '1')
                r['ins'].append(e)
        ac = 1 if s.get(grp + 'CLR_SEL') == '1' else 0
        if ac == 0:
            sel = L.get('ACLR0_SEL', 'DIN3')
            port = f'{lab}:DATAIN.3' if sel == 'DIN3' else None
        else:
            sel = L.get('ACLR1_SEL', 'DIN2')
            port = f'{lab}:DATAIN.2' if sel == 'DIN2' else None
        if port and port in self.drv:
            e = self.canon(self.source(port))
            r['aclr'] = ('~' if L.get(f'ACLR{ac}_INV') == '1' else '') + self.name(e) + ' (?)'
            r['ins'].append(e)
        return r

    def reg_next(self, alm, ff, q, val):
        """Next value of a register given its current value q and val(signal)."""
        r = self.reg(alm, ff)
        if 'en_sig' in r:
            e, inv = r['en_sig']
            if val(e) == inv:
                return q
        if 'sclr_sig' in r:
            e, inv = r['sclr_sig']
            if val(e) != inv:
                return 0
        if r.get('sload_sig'):
            e, inv, sd = r['sload_sig']
            if val(e) != inv:
                return val(sd)
        return val(r['d_sig'])

    def reg_text(self, alm, ff):
        r = self.reg(alm, ff)
        d = r['d']
        if 'sload' in r and r['sload']:
            d = f"{r['sload']} ? {r['sdata']} : {d}"
        if 'sclr' in r:
            d = f"{r['sclr']} ? 0 : ({d})"
        t = f"<= {d}   @{r['clk']}"
        if 'en' in r:
            t += f" en={r['en']}"
        if 'aclr' in r:
            t += f" aclr={r['aclr']}"
        return t, r['ins']

    # -- node expansion
    def node(self, sig):
        """-> (text, input signals) for a canonical signal, or None for leaves."""
        m = re.match(r'((?:M?LAB)\.\d+\.\d+\.\d+):(T|B|FF[TB][01])$', sig)
        if not m:
            return None
        alm, what = m[1], m[2]
        if what in ('T', 'B'):
            e, ins, kind = self.comb(alm, what)
            return f'= {e}', ins
        return self.reg_text(alm, what)

    def users(self, sig):
        """Signals/sinks directly driven by a canonical signal."""
        m = re.match(r'((?:M?LAB)\.\d+\.\d+\.\d+):(T|B)$', sig)
        if m:   # comb half: its ports and the FFs it feeds
            alm, half = m[1], m[2]
            ports = [f'{alm}:{p}' for p in FF_DFF if p[2] == half]
            out = set()
            s = self.alm[alm]
            for p in ports:
                if s.get(FF_DFF[p.split(':')[1]]) == 'NLUT' and p in self.fan:
                    out |= set(self.sinks(p))
            for ff in ('FFT0', 'FFT1') if half == 'T' else ('FFB0', 'FFB1'):
                if s.get(FF_PK[ff]) != '1' and s.get(FF_GRP[ff] + 'CLK_SEL') and \
                        self.ff_used(alm, ff):
                    out.add(f'{alm}:{ff}')
            return out
        ports = []
        m = re.match(r'((?:M?LAB)\.\d+\.\d+\.\d+):(FF[TB][01])$', sig)
        if m:
            alm, ff = m[1], m[2]
            ports = [f'{alm}:{ff}'] + ([f'{alm}:{ff}L'] if ff.endswith('1') else [])
            ports = [p for p in ports if self.alm[alm].get(FF_DFF[p.split(':')[1]]) != 'NLUT']
        else:
            ports = [sig]
        out = set()
        for p in ports:
            out |= set(self.sinks(p))
        if m and self.FEEDBACK and self.feedback(alm, ff[2]) == sig:
            out.add(f'{alm}:{ff[2]}F')    # the half's feedback line (pseudo pin TF/BF)
        return out

    def ff_used(self, alm, ff):
        ports = [ff] + ([ff + 'L'] if ff.endswith('1') else [])
        return any(f'{alm}:{p}' in self.fan and self.alm[alm].get(FF_DFF[p]) != 'NLUT'
                   for p in ports)

    def sink_targets(self, port):
        """Map a sink port to the canonical signals it affects (or itself if a leaf)."""
        m = re.match(r'((?:M?LAB)\.\d+\.\d+\.\d+):(\w+)$', port)
        if m and m[2] in ALM_PINS + ('TF', 'BF'):
            alm, pin = m[1], m[2]
            s = self.alm[alm]
            out = set()
            for half in 'TB':
                spec = self.half_spec(alm, half)
                if spec is None:
                    out.add(port)
                    continue
                e, ins, kind = self.comb(alm, half)
                src = self.sig_of_pin(alm, pin)
                if src in ins and (self.users(f'{alm}:{half}')):
                    out.add(f'{alm}:{half}')
            for ff in FF_PK:
                half = ff[2]
                if half == 'T':
                    sdpin = 'F1' if s.get('TEF_SEL') == 'F' else 'E0'
                else:
                    sdpin = 'F0' if s.get('BEF_SEL') == 'F' else 'E1'
                if pin == sdpin and self.ff_used(alm, ff) and s.get(FF_GRP[ff] + 'CLK_SEL') and \
                        (s.get(FF_PK[ff]) == '1' or s.get(half + 'SLOAD_EN') == '1'):
                    out.add(f'{alm}:{ff}')
            return out
        m = re.match(r'((?:M?LAB)\.\d+\.\d+):(DATAIN|CLKIN)\.(\d)$', port)
        if m:
            lab = m[1]
            out = set()
            for a in range(10):
                alm = f'{lab}.{a}'
                for ff in FF_PK:
                    if self.ff_used(alm, ff) and self.alm[alm].get(FF_GRP[ff] + 'CLK_SEL'):
                        r = self.reg(alm, ff)
                        if self.canon(self.source(port)) in r['ins'] or m[2] == 'CLKIN':
                            out.add(f'{alm}:{ff}')
            return out
        return {port}


class Sim:
    """Cycle simulation of a set of registers (one clock). Signals that are neither
    simulated registers nor comb halves come from `inp` or `fixed` (KeyError
    otherwise). Registers start at 0 (Cyclone V power-up)."""

    def __init__(self, design, regs, fixed=None):
        self.D = design
        self.regs = list(regs)
        self.state = {r: 0 for r in self.regs}
        self.fixed = dict(fixed or {})
        self.inp = {}

    def val(self, sig, memo):
        if sig in memo:
            return memo[sig]
        if sig == 'const1':
            v = 1
        elif sig == 'const0':
            v = 0
        elif sig.startswith('cout:'):
            _, alm, h = sig.split(':')
            v = self.D.eval_arith(alm, h, lambda s: self.val(s, memo))[1]
        elif sig in self.inp:
            v = self.inp[sig]
        elif sig in self.state:
            v = self.state[sig]
        elif sig in self.fixed:
            v = self.fixed[sig]
        else:
            m = re.match(r'((?:M?LAB)\.\d+\.\d+\.\d+):(T|B)$', sig)
            if not m:
                raise KeyError(sig)
            v = self.D.eval_comb(m[1], m[2], lambda s: self.val(s, memo))
        memo[sig] = v
        return v

    def peek(self, sig):
        return self.val(sig, {})

    def step(self):
        memo = {}
        self.state = {r: self.D.reg_next(*r.split(':'), self.state[r],
                                         lambda s: self.val(s, memo)) for r in self.regs}


def resolve_seed(D, seed):
    """-> (forward start signals, backward start signals)"""
    if seed in D.pins:
        g = D.pins[seed]
        fwd, back = [], []
        for k in range(4):                # .3 = IOE input register path
            p = f'{g}:DATAIN.{k}'
            if p in D.fan:
                fwd.append(p)
        for k in range(2):
            for kind in ('DATAOUT', 'OEIN'):
                p = f'{g}:{kind}.{k}'
                if p in D.drv:
                    back.append(D.canon(D.source(p)))
        return fwd, back
    if ':' in seed:
        # ALM:T / ALM:B are comb halves (not the routed A/B/... input pins)
        if seed in D.drv and not re.search(r':(FF[TB]|T$|B$)', seed):   # sink port
            return [], [D.canon(D.source(seed))]
        c = D.canon(seed)
        return [c], [c]
    raise SystemExit(f'unknown seed {seed}')


def main():
    args = sys.argv[1:]
    opts = {'--back': 3, '--fwd': 3, '--names': None, '--pins': None, '--hmc': None}
    raw = False
    seeds = []
    path = args.pop(0)
    while args:
        a = args.pop(0)
        if a in opts:
            opts[a] = args.pop(0)
        elif a == '--raw':
            raw = True
        else:
            seeds.append(a)
    pinfile = opts['--pins'] or __file__.rsplit('/', 2)[0] + '/build/f23-pins.txt'
    D = Design(path, pinfile, opts['--names'], opts['--hmc'])
    nodes, leaves_in, leaves_out = {}, set(), defaultdict(set)

    def expand_back(sig, depth):
        if sig in nodes and nodes[sig][1] >= depth:
            return
        n = D.node(sig)
        if n is None:
            leaves_in.add(sig)
            return
        nodes[sig] = (n, max(depth, nodes.get(sig, (None, -1))[1]))
        if depth > 0:
            for i in n[1]:
                expand_back(i, depth - 1)

    def expand_fwd(sig, depth, seen):
        if (sig, depth) in seen or depth < 0:
            return
        seen.add((sig, depth))
        n = D.node(sig)
        if n is not None and sig not in nodes:
            nodes[sig] = (n, 0)
        if depth == 0:
            return
        for p in D.users(sig):
            for t in D.sink_targets(p):
                if D.node(t) is None and t == p:
                    leaves_out[sig].add(p)
                    continue
                expand_fwd(t, depth - 1, seen)

    seen = set()
    for s in seeds:
        fwd, back = resolve_seed(D, s)
        for f in fwd:
            expand_fwd(D.canon(f), int(opts['--fwd']), seen)
        for b in back:
            expand_back(b, int(opts['--back']))

    def key(sig):
        return [int(x) if x.isdigit() else x for x in re.split(r'[.:]', sig)]

    print('# inputs (leaves):', ' '.join(sorted(D.name(x) for x in leaves_in)) or '-')
    for sig in sorted(nodes, key=key):
        (text, ins), _ = nodes[sig]
        line = f'{D.name(sig)} {text}'
        if raw:
            alm = sig.split(':')[0]
            s = D.alm.get(alm, {})
            line += f"   [mask {D.masks.get(alm, 0):016x} T={s.get('TMODE', 'D_E')} " \
                    f"B={s.get('BMODE', 'C_E')}{' ARITH' if s.get('ARITH_SEL') else ''}]"
        print(line)
        if sig in leaves_out:
            print('    -> ' + ' '.join(sorted(leaves_out[sig])))


if __name__ == '__main__':
    main()
