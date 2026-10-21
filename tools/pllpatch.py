#!/usr/bin/env python3
"""Drive global clocks of a nextpnr-built design from Cyclone V fPLLs, by patching the bitstream.

nextpnr-mistral has no PLL support, but it does route clock nets through a global clock mux
(CMUXHG.<x>.022, mux index 2) whose input is selected by INPUT_SEL (0x1b = fabric). A design
instantiates a placeholder clock buffer (MISTRAL_CLKBUF, input = the 74.25 MHz reference pin);
after place and route this tool configures an fPLL from Quartus-proven settings copied from
spc.bt and points the buffer's clock mux at the fPLL output. See notes/pll.md.

  pllpatch.py decode FILE.bt|FILE.rbf
        fPLL settings decoded to M/N/K/C, VCO and output frequencies, and which clock muxes
        select which fPLL outputs.
  pllpatch.py solve MHz [MHz...] [profile=NAME] [tol=PPM]
        counter settings that make these frequencies on one fPLL (outputs C0, C1, ...).
  pllpatch.py patch CFG DESIGN.rbf ROUTED.json SPC.bt OUT.bt
        write the .bt edits for tools/mistral-patch.
  pllpatch.py check CFG DESIGN.rbf PATCHED.rbf PATCH.bt
        decompile both bitstreams (must give no mistral errors), check that they differ only
        in the patch's lines, and that every configured clock now comes from the requested
        fPLL output at the requested frequency.

CFG (hw/<name>/pll.cfg), one line per placeholder clock buffer:
  <clkbuf instance> <MHz> [pll=FPLL.x.y] [out=Cn] [profile=NAME] [tol=PPM]
Defaults: pll = the W16-fed fPLL on the side nextpnr placed the buffer (FPLL.000.000 for
CMUXHG.000.022, FPLL.054.000 for CMUXHG.054.022), out = C0 (C1, C2, C3 for further lines on the
same fPLL), profile = the first one that hits the frequency within tol (default 1 ppm).
"""
import json
import os
import re
import subprocess
import sys
import tempfile
from fractions import Fraction

TOOLS = os.path.dirname(os.path.abspath(__file__))
MODEL = '5CEBA4F23C8'
REF_MHZ = Fraction('74.25')         # W16 and H16 (notes/spc-core.md, "Clock inputs")
VCO_MIN, VCO_MAX = 600, 1300        # Cyclone V -C8 fPLL VCO range, MHz (datasheet)
C_MAX = 510                         # hi/lo counts are 8 bits each; 0 (= 256?) avoided

# Loop configurations (M, N, bandwidth, charge pump, ...) taken verbatim from Quartus-built PLLs
# in spc.bt. Only the output counters (and, for 'frac8', the fractional part K of M) change, so
# the PFD/VCO loop stays one that Quartus chose. Order = preference (integer modes first).
PROFILES = {
    # name: (source fPLL in spc.bt, kind, VCO range MHz)
    'int28n2':   ('FPLL.054.000', 'int', None),               # 74.25*28/2 = 1039.5 MHz
    'int16':     ('FPLL.000.037', 'int', None),               # 74.25*16   = 1188 MHz
    'int142n13': ('FPLL.054.037', 'int', None),               # 74.25*142/13 = 811.04 MHz
    'frac8':     ('FPLL.000.000', 'frac', (600, 668.25)),     # 74.25*(8+K/2^32), 600-668 MHz
}
# Settings that depend on the fPLL's position / reference pin rather than on the frequency:
# copied from spc's own configuration of the target fPLL.
POSITION_KEYS = {'CLKIN_0_SRC', 'CLKIN_1_SRC', 'NREVERT_INVERT', 'PL_AUX_BG_POWERDOWN'}
COUNTER_RE = re.compile(r'^(C\d_COUT_EN|C\d_EXTCLK_DLLOUT_EN|CNT_IN_SRC\.\d|CNT_PRESET\.\d|'
                        r'CNT_PH_MUX_PRESET\.\d|DPRIO0_CNT_HI_DIV\.\d|DPRIO0_CNT_LO_DIV\.\d|'
                        r'DPRIO0_CNT_ODD_DIV_EVEN_DUTY_EN\.\d|BYPASS_EN\.\d|CNT_COARSE_DELAY\.\d|'
                        r'CNT_FINE_DELAY\.\d|SRC\.\d)$')
FRAC_KEYS = {'M_CNT_HI_DIV_SETTING', 'M_CNT_LO_DIV_SETTING', 'FRACTIONAL_DIVISION_SETTING'}


def die(msg):
    sys.exit('pllpatch: ' + msg)


# ---------------------------------------------------------------- mistral data

_pllinfo = None


def pllinfo():
    """Fixed wiring from tools/pllinfo: ref pins, PLLCOUT -> CMUX PLLIN, INPUT_SEL tables."""
    global _pllinfo
    if _pllinfo:
        return _pllinfo
    out = subprocess.run([os.path.join(TOOLS, 'pllinfo'), MODEL], check=True,
                         capture_output=True, text=True).stdout
    clkin, outs, sel = {}, {}, {}
    for line in out.splitlines():
        f = line.split()
        if f[0] == 'clkin':                       # clkin FPLL n PIN GPIO
            clkin[(f[1], int(f[2]))] = (f[3], f[4])
        elif f[0] == 'out':                       # out FPLL n CMUX m
            outs[(f[1], int(f[2]))] = outs.get((f[1], int(f[2])), []) + [(f[3], int(f[4]))]
        elif f[0] == 'sel':                       # sel TYPE z VAL KIND idx
            sel[(f[1], int(f[2]), int(f[3], 16))] = (f[4], int(f[5]))
    _pllinfo = clkin, outs, sel
    return _pllinfo


def decompile(rbf):
    """mistral-cv decomp; any stderr output counts as a decode error."""
    with tempfile.NamedTemporaryFile(suffix='.bt') as t:
        r = subprocess.run([os.path.join(TOOLS, 'mistral-cv'), 'decomp', MODEL, rbf, t.name],
                           capture_output=True, text=True)
        if r.returncode or r.stderr.strip():
            die(f'mistral-cv decomp {rbf} failed or reported errors:\n{r.stderr}')
        return open(t.name).read().splitlines()


def load_bt(path):
    return decompile(path) if path.endswith('.rbf') else open(path).read().splitlines()


def bt_key(line):
    """Identity of a .bt line: 's X:Y' / 'i X' / 'r * DST' (a route is keyed by its sink)."""
    f = line.split(' ; ')[0].split()
    if not f:
        return None
    if f[0] in ('s', 'i'):
        return (f[0], f[1])
    if f[0] == 'r':
        return ('r', f[2])
    return (f[0],)


def settings(lines):
    """{'BLOCK.x.y': {'MUX.i': value}} from 's' lines; {'BLOCK.x.y': {...}} for 'i' too."""
    s = {}
    for line in lines:
        if line.startswith('s ') or line.startswith('i '):
            f = line.split(' ; ')[0].split()
            blk, _, mux = f[1].partition(':')
            s.setdefault(blk, {})[(f[0], mux)] = f[2]
    return s


# ---------------------------------------------------------------- fPLL arithmetic

def hilo(st, hi, lo, dhi=1, dlo=1):
    h = int(st.get(('s', hi), '%x' % dhi), 16) or 256
    l = int(st.get(('s', lo), '%x' % dlo), 16) or 256
    return h + l


def decode_pll(name, st):
    """Decode one fPLL's settings like notes/spc-core.md does. Returns a dict."""
    clkin, _, _ = pllinfo()
    g = lambda k, d: st.get(('s', k), d)
    src = int(g('CLKIN_0_SRC', '2'), 16)
    pin = clkin.get((name, src - 4), ('?',))[0] if src >= 4 else f'src {src}?'
    n = 1 if g('N_CNT_BYPASS_EN', '0') == '1' else hilo(st, 'N_CNT_HI_DIV_SETTING', 'N_CNT_LO_DIV_SETTING')
    m = 1 if g('M_CNT_BYPASS_EN', '0') == '1' else hilo(st, 'M_CNT_HI_DIV_SETTING', 'M_CNT_LO_DIV_SETTING')
    k = int(g('FRACTIONAL_DIVISION_SETTING', '0'), 16)
    # Quartus writes K=1 in integer-mode fPLLs (DSM_OUT_SEL 0 or 3); 2^-32 either way, ignored.
    vco = REF_MHZ * (m + (Fraction(k, 2**32) if k > 1 else 0)) / n
    outs = {}
    for c in range(9):
        if g(f'C{c}_COUT_EN', '0') != '1':
            continue
        div = 1 if g(f'BYPASS_EN.{c}', '0') == '1' else hilo(st, f'DPRIO0_CNT_HI_DIV.{c}', f'DPRIO0_CNT_LO_DIV.{c}')
        notes = []
        if g(f'CNT_IN_SRC.{c}', '2') != '0':
            notes.append(f'CNT_IN_SRC {g(f"CNT_IN_SRC.{c}", "2")} (not the VCO?)')
        if (('s', f'CNT_PRESET.{c}') in st) or (('s', f'CNT_PH_MUX_PRESET.{c}') in st):
            notes.append(f'phase preset {g(f"CNT_PRESET.{c}", "01")}/{g(f"CNT_PH_MUX_PRESET.{c}", "0")}')
        outs[c] = (div, vco / div, notes)
    return dict(enabled=g('FPLL_ENABLE', '0') == '1', pin=pin, n=n, m=m, k=k, vco=vco, outs=outs,
                dsm=g('DSM_OUT_SEL', '0'), bw=g('BWCTRL', '4'), cp=g('CP_CURRENT', '2'))


def cmux_sources(st):
    """[(CMUX.x.y.z, FPLL, n)] for every clock mux whose INPUT_SEL picks an fPLL output."""
    _, outs, sel = pllinfo()
    rev = {}
    for (pll, n), dsts in outs.items():
        for d in dsts:
            rev[d] = (pll, n)
    res = []
    for blk, kv in st.items():
        if not blk.startswith('CMUX'):
            continue
        typ = blk.split('.')[0]
        for (kind, mux), val in kv.items():
            if kind == 's' and mux.startswith('INPUT_SEL.'):
                z = int(mux.split('.')[1])
                link = sel.get((typ, z, int(val, 16)))
                if link and link[0] == 'PLLIN' and (blk, link[1]) in rev:
                    res.append((f'{blk}.{z}', *rev[(blk, link[1])], val))
    return sorted(res)


def fmt_mhz(f):
    return f'{float(f):.6f}'


def cmd_decode(path):
    st = settings(load_bt(path))
    plls = {}
    for blk in sorted(st):
        if blk.startswith('FPLL.'):
            d = plls[blk] = decode_pll(blk, st[blk])
            print(f'{blk}: {"enabled" if d["enabled"] else "DISABLED"}, ref {d["pin"]} '
                  f'({fmt_mhz(REF_MHZ)} MHz assumed), N={d["n"]} M={d["m"]} K=0x{d["k"]:08x} '
                  f'(M+K/2^32={float(d["m"] + Fraction(d["k"], 2**32)):.7f}), VCO {fmt_mhz(d["vco"])} MHz, '
                  f'BWCTRL {d["bw"]} CP_CURRENT {d["cp"]} DSM_OUT_SEL {d["dsm"]}')
            for c, (div, f, notes) in d['outs'].items():
                print(f'    C{c}: /{div} = {fmt_mhz(f)} MHz' + (f'  [{"; ".join(notes)}]' if notes else ''))
    for cm, pll, n, val in cmux_sources(st):
        f = plls.get(pll, {}).get('outs', {}).get(n)
        print(f'{cm} INPUT_SEL {val} <- {pll} PLLCOUT.{n}' +
              (f' = {fmt_mhz(f[1])} MHz' if f else ' (output not enabled!)'))


# ---------------------------------------------------------------- solving

def profile_loop(spc_st, prof):
    """(M, N, K, VCO) of a profile's source PLL."""
    d = decode_pll(PROFILES[prof][0], spc_st[PROFILES[prof][0]])
    return d


def solve(freqs, spc_st, profile=None, tol_ppm=1.0):
    """freqs: {counter: Fraction MHz}. Returns (profile, m_int, k, vco, {counter: div}, worst_ppm)."""
    names = [profile] if profile else list(PROFILES)
    best = None
    for prof in names:
        src, kind, vrange = PROFILES[prof]
        d = decode_pll(src, spc_st[src])
        if kind == 'int':
            cand = [(d['m'], 0, d['vco'])]
        else:
            if d['n'] != 1:
                die(f'profile {prof}: expected N=1')
            lo, hi = vrange
            c0, f0 = min(freqs.items())
            cand = []
            for div in range(2, C_MAX + 1):
                vco = f0 * div
                if lo <= vco < hi:
                    meff = vco / REF_MHZ
                    k = round((meff - int(meff)) * 2**32)
                    if int(meff) == d['m'] and 0 < k < 2**32:
                        cand.append((d['m'], k, REF_MHZ * (d['m'] + Fraction(k, 2**32))))
        for m, k, vco in cand:
            divs, worst = {}, 0.0
            for c, f in freqs.items():
                div = round(vco / f)
                if not 2 <= div <= C_MAX:
                    break
                ppm = abs(float((vco / div - f) / f)) * 1e6
                divs[c], worst = div, max(worst, ppm)
            else:
                if not VCO_MIN <= vco <= VCO_MAX:
                    continue
                if worst <= tol_ppm:
                    return prof, m, k, vco, divs, worst
                if best is None or worst < best[-1]:
                    best = (prof, m, k, vco, divs, worst)
    die(f'no profile makes {", ".join(fmt_mhz(f) for f in freqs.values())} MHz within {tol_ppm} ppm'
        + (f' (best: {best[0]}, {best[-1]:.1f} ppm; raise tol=)' if best else ''))


def pll_lines(target, freqs, spc_lines, spc_st, profile=None, tol_ppm=1.0):
    """.bt lines configuring fPLL `target` for {counter: MHz}, plus a description."""
    prof, m, k, vco, divs, worst = solve(freqs, spc_st, profile, tol_ppm)
    src = PROFILES[prof][0]
    if target not in spc_st:
        die(f'{target} is not configured in spc.bt, no position-specific settings to copy')
    lines = []
    for (kind, mux), val in sorted(spc_st[src].items()):
        if kind == 's' and mux not in POSITION_KEYS and not COUNTER_RE.match(mux):
            if PROFILES[prof][1] == 'frac' and mux in FRAC_KEYS:
                continue
            lines.append(f's {target}:{mux} {val}')
    if PROFILES[prof][1] == 'frac':
        lines += [f's {target}:M_CNT_HI_DIV_SETTING {(m + 1) // 2:02x}',
                  f's {target}:M_CNT_LO_DIV_SETTING {m // 2:02x}',
                  f's {target}:FRACTIONAL_DIVISION_SETTING {k:08x}']
        if m % 2:
            die('odd integer M in fractional mode is not covered by any reference')
    for (kind, mux), val in sorted(spc_st[target].items()):
        if kind == 's' and mux in POSITION_KEYS:
            lines.append(f's {target}:{mux} {val}')
    for c, div in sorted(divs.items()):
        hi, lo = (div + 1) // 2, div // 2
        lines += [f's {target}:C{c}_COUT_EN 1', f's {target}:CNT_IN_SRC.{c} 0',
                  f's {target}:DPRIO0_CNT_HI_DIV.{c} {hi:02x}', f's {target}:DPRIO0_CNT_LO_DIV.{c} {lo:02x}']
        if div % 2:
            lines.append(f's {target}:DPRIO0_CNT_ODD_DIV_EVEN_DUTY_EN.{c} 1')
    # The NRESET0 inverter of the target fPLL as in spc (its NRESET0 input is undriven there).
    # spc.bt also shows "r TCLK.<x>.<y>.0004 FPLL...:FBCLK_IN_R0" for every fPLL, but those mux
    # bits are at their default in nextpnr's output too (a decompiler quirk prints them for spc
    # only), so there is nothing to copy.
    for line in spc_lines:
        if line.startswith(f'i {target}:NRESET0 '):
            lines.append(line)
    desc = (f'{target}: profile {prof} (loop from spc {src}), M={m}' +
            (f'+0x{k:08x}/2^32' if k else '') + f', VCO {fmt_mhz(vco)} MHz, ' +
            ', '.join(f'C{c} /{d} = {fmt_mhz(vco / d)} MHz' for c, d in sorted(divs.items())) +
            f' (worst {worst:.3g} ppm)')
    return lines, desc


def cmd_solve(args):
    kw = dict(a.split('=', 1) for a in args if '=' in a)
    freqs = {i: Fraction(a) for i, a in enumerate(a for a in args if '=' not in a)}
    spc_lines = open(kw.get('spc', os.path.join(TOOLS, '..', 'build', 'spc.bt'))).read().splitlines()
    spc_st = settings(spc_lines)
    lines, desc = pll_lines(kw.get('pll', 'FPLL.000.000'), freqs, spc_lines, spc_st,
                            kw.get('profile'), float(kw.get('tol', 1)))
    print('; ' + desc)
    print('\n'.join(lines))


# ---------------------------------------------------------------- config / placement

def read_cfg(path):
    ents = []
    for ln, line in enumerate(open(path), 1):
        f = line.split('#')[0].split()
        if not f:
            continue
        if len(f) < 2:
            die(f'{path}:{ln}: expected "<clkbuf> <MHz> [pll=] [out=] [profile=] [tol=]"')
        kw = {}
        for a in f[2:]:
            k, eq, v = a.partition('=')
            if not eq or k not in ('pll', 'out', 'profile', 'tol'):
                die(f'{path}:{ln}: bad option {a}')
            kw[k] = v
        if kw.get('profile') and kw['profile'] not in PROFILES:
            die(f'{path}:{ln}: unknown profile {kw["profile"]} ({", ".join(PROFILES)})')
        ents.append(dict(name=f[0], mhz=Fraction(f[1]), line=ln, **kw))
    return ents


def clkbuf_places(routed):
    """{cell name: 'CMUXHG.x.y'} for MISTRAL_CLKBUF cells in nextpnr's --write JSON."""
    d = json.load(open(routed))
    res = {}
    for mod in d['modules'].values():
        nets = {}
        for nn, nv in mod.get('netnames', {}).items():
            for b in nv['bits']:
                nets.setdefault(b, []).append(nn)
        for cn, c in mod['cells'].items():
            if c['type'] in ('MISTRAL_CLKBUF', 'MISTRAL_CLKENA'):
                bel = c['attributes'].get('NEXTPNR_BEL', '')
                m = re.match(r'MISTRAL_CLKENA\.(\d+)\.(\d+)\.\d+$', bel)
                if not m:
                    die(f'clock buffer {cn} has unexpected bel {bel!r}')
                place = f'CMUXHG.{int(m[1]):03d}.{int(m[2]):03d}'
                res[cn] = place
                for b in c['connections'].get('Q', []):     # also findable by output net name
                    for nn in nets.get(b, []):
                        res.setdefault(nn, place)
    return res


def plan(cfg, routed, design_st):
    """Resolve config lines: [(entry, cmux, pll, counter)]."""
    _, outs, sel = pllinfo()
    places = clkbuf_places(routed)
    used, res = {}, []
    for e in cfg:
        if e['name'] not in places:
            die(f'line {e["line"]}: no clock buffer "{e["name"]}" in {routed} '
                f'(have: {", ".join(sorted(places))})')
        cmux = places[e['name']]
        cur = design_st.get(cmux, {}).get(('s', 'INPUT_SEL.2'))
        if cur != '1b':
            die(f'{cmux}:INPUT_SEL.2 is {cur} in the design, expected 1b (fabric input)')
        pll = e.get('pll') or {'000': 'FPLL.000.000', '054': 'FPLL.054.000'}[cmux.split('.')[1]]
        if 'out' in e:
            ctr = int(e['out'].lstrip('Cc'))
        else:
            ctr = next(c for c in range(4) if (pll, c) not in used)
        if (pll, ctr) in used:
            die(f'line {e["line"]}: {pll} C{ctr} already used by line {used[(pll, ctr)]}')
        used[(pll, ctr)] = e['line']
        pllin = [m for d, m in outs.get((pll, ctr), []) if d == cmux]
        if not pllin:
            reach = sorted(f'{p} C{c}' for (p, c), ds in outs.items() for d, _ in ds if d == cmux)
            die(f'line {e["line"]}: {pll} C{ctr} cannot reach {cmux} (it can take: {", ".join(reach)}); '
                f'pin the buffer with (* BEL = "MISTRAL_CLKENA.<x>.22.0" *) or choose another pll=/out=')
        val = [v for (t, z, v), (kind, i) in sel.items()
               if t == 'CMUXHG' and z == 2 and kind == 'PLLIN' and i == pllin[0]]
        res.append((e, cmux, pll, ctr, f'{val[0]:02x}'))
    return res


def check_design(design_st, pll, spc_st):
    """The design must not use the fPLL already and must have its reference pin as an input."""
    if pll in design_st:
        die(f'{pll} already has settings in the design: {design_st[pll]}')
    clkin, _, _ = pllinfo()
    src = int(spc_st[pll].get(('s', 'CLKIN_0_SRC'), '2'), 16)
    pin, gpio = clkin[(pll, src - 4)]
    blk, idx = gpio.rsplit('.', 1)
    if design_st.get(blk, {}).get(('s', f'USE_WEAK_PULLUP.{idx}')) != '0':
        die(f'{pll} takes its reference from pin {pin} ({gpio}), which the design does not use as an '
            f'input. Declare it as the input that feeds the placeholder clock buffer.')
    return pin


def cmd_patch(cfg_path, design_rbf, routed, spc_bt, out_bt):
    cfg = read_cfg(cfg_path)
    design_st = settings(load_bt(design_rbf))
    if not os.path.exists(routed) or os.path.getmtime(routed) < os.path.getmtime(design_rbf) - 5:
        die(f'{routed} is missing or older than {design_rbf}; delete {design_rbf} and rebuild '
            f'(nextpnr writes it when hw/<name>/pll.cfg exists)')
    spc_lines = open(spc_bt).read().splitlines()
    spc_st = settings(spc_lines)
    by_pll = {}
    for e, cmux, pll, ctr, val in plan(cfg, routed, design_st):
        by_pll.setdefault(pll, []).append((e, cmux, ctr, val))
    out = [f'; generated by tools/pllpatch.py from {cfg_path}; apply with tools/mistral-patch', f'm {MODEL}']
    for pll, ents in sorted(by_pll.items()):
        pin = check_design(design_st, pll, spc_st)
        profs = {e.get('profile') for e, *_ in ents}
        tols = [float(e.get('tol', 1)) for e, *_ in ents]
        lines, desc = pll_lines(pll, {ctr: e['mhz'] for e, _, ctr, _ in ents}, spc_lines, spc_st,
                                profs.pop() if len(profs) == 1 else None, min(tols))
        out.append(f'; {desc}, reference pin {pin}')
        out += lines
        for e, cmux, ctr, val in ents:
            out.append(f'; {e["name"]}: {cmux} mux 2 <- {pll} C{ctr} (PLLIN select {val})')
            out.append(f's {cmux}:INPUT_SEL.2 {val}')
        print('pllpatch: ' + desc)
    open(out_bt, 'w').write('\n'.join(out) + '\n')


def cmd_check(cfg_path, design_rbf, patched_rbf, patch_bt):
    base = load_bt(design_rbf)
    new = load_bt(patched_rbf)
    patch = [l for l in open(patch_bt).read().splitlines() if l and l[0] in 'sri']
    pkeys = {bt_key(l): l.split(' ; ')[0].strip() for l in patch}
    bset, nset = set(base), set(new)
    removed, added = sorted(bset - nset), sorted(nset - bset)
    bad = [l for l in removed + added if bt_key(l) not in pkeys]
    if bad:
        die('patched bitstream differs from the design outside the patch:\n  ' + '\n  '.join(bad[:20]))
    nkeys = {bt_key(l): l.split(' ; ')[0].strip() for l in new}
    for k, l in pkeys.items():
        if nkeys.get(k, l) != l:
            die(f'patch line "{l}" decodes as "{nkeys[k]}"')
        if k not in nkeys:
            print(f'pllpatch: note: "{l}" is a default value (not printed by the decompiler)')
    st = settings(new)
    srcs = {cm: (pll, n) for cm, pll, n, _ in cmux_sources(st)}
    # "; <name>: <CMUX> mux 2 <- ..." comments written by cmd_patch
    where = {l.split()[1].rstrip(':'): l.split()[2] for l in open(patch_bt)
             if l.startswith('; ') and ' mux 2 <- ' in l}
    for e in read_cfg(cfg_path):
        if e['name'] not in where:
            die(f'{e["name"]} not in {patch_bt}')
        cmux = where[e['name']]
        pll, n = srcs.get(cmux + '.2', (None, None))
        if pll is None:
            die(f'{cmux}.2 does not select an fPLL output after patching')
        d = decode_pll(pll, st[pll])
        if n not in d['outs'] or not d['enabled']:
            die(f'{pll} C{n} is not enabled after patching')
        f = d['outs'][n][1]
        ppm = abs(float((f - e['mhz']) / e['mhz'])) * 1e6
        tol = float(e.get('tol', 1))
        if ppm > tol:
            die(f'{e["name"]}: decoded {fmt_mhz(f)} MHz, wanted {fmt_mhz(e["mhz"])} ({ppm:.2f} ppm)')
        print(f'pllpatch: ok: {e["name"]} = {cmux}.2 <- {pll} C{n} = {fmt_mhz(f)} MHz '
              f'(ref {d["pin"]}, VCO {fmt_mhz(d["vco"])} MHz, {ppm:.3g} ppm from {fmt_mhz(e["mhz"])})')
    print(f'pllpatch: ok: {len(removed)} lines removed, {len(added)} added, all from {patch_bt}; '
          f'no decode errors')


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    cmd, args = argv[1], argv[2:]
    if cmd == 'decode' and len(args) == 1:
        cmd_decode(args[0])
    elif cmd == 'solve' and args:
        cmd_solve(args)
    elif cmd == 'patch' and len(args) == 5:
        cmd_patch(*args)
    elif cmd == 'check' and len(args) == 4:
        cmd_check(*args)
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main(sys.argv)
