// Turn a nextpnr-mistral (or any mistral-readable) .rbf into a Super Nt jailbreak .cor.
//
// Usage: rbf2cor model in.rbf ref.rbf out.cor [--jtag-id ref|sum|keep|<hex>] [--keep-io]
//
//   in.rbf   design bitstream, compressed or not (e.g. nextpnr-mistral --rbf output)
//   ref.rbf  a known-good core, bit-reversed back to .rbf (build/spc.rbf)
//   out.cor  written uncompressed and bit-reversed, ready for SYSTEM/CORES/ on the SD card
//
// Option frame: every option (OPT_B, JTAG_ID, ...) is copied from ref.rbf so the option frame is
// byte-identical to the reference core's, then COMPRESSION_DIS is forced on. nextpnr-mistral
// writes OPT_B ffffff40.adffffff and leaves JTAG_ID at ffffffff; Quartus' spc.cor has
// ffffff40.2dffffff and 03cbd16e. --jtag-id picks the JTAG_ID (user code) instead:
//   ref  (default) ref's value     sum  mistral's compute_default_jtag_id() (CRAM byte sum)
//   keep in.rbf's value            <hex> explicit value
//
// I/O standard: nextpnr hardcodes outputs to V3P3_LVTTL_16MA drive and leaves inputs at the
// default. Unless --keep-io is given, every pad the design uses gets the reference core's
// DRIVE_STRENGTH setting for the same pad (V2P5_50OHM on the pins the SPC core uses). Pads with
// no DRIVE_STRENGTH in the reference (e.g. its pure inputs W16/H16) are reported and left alone.
//
// The result is re-read with libmistral and compared with the design (every block setting,
// route, inverter and option), and must re-encode to identical bytes; otherwise nothing is
// written and the exit code is 3.
#include "cyclonev.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <set>
#include <string>
#include <vector>

using mistral::CycloneV;

static std::vector<uint8_t> load(const char *fname)
{
  FILE *f = fopen(fname, "rb");
  if(!f) { perror(fname); exit(2); }
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  std::vector<uint8_t> d(n);
  if(fread(d.data(), 1, n, f) != size_t(n)) { perror(fname); exit(2); }
  fclose(f);
  return d;
}

static uint8_t rev8(uint8_t b)
{
  b = (b & 0xf0) >> 4 | (b & 0x0f) << 4;
  b = (b & 0xcc) >> 2 | (b & 0x33) << 2;
  b = (b & 0xaa) >> 1 | (b & 0x55) << 1;
  return b;
}

// RAM-type options come back as packed little-endian bytes.
static uint64_t get_r64(const CycloneV *m, CycloneV::bmux_type_t mux)
{
  CycloneV::opt_setting_t s;
  m->opt_get(mux, s);
  uint64_t v = 0;
  for(size_t i = 0; i != s.r.size() && i != 8; i++)
    v |= uint64_t(s.r[i]) << (8 * i);
  return v;
}

static void copy_options(const CycloneV *src, CycloneV *dst)
{
  for(const auto &o : src->opt_get()) {
    switch(o.type) {
    case CycloneV::MT_MUX:  dst->opt_m_set(o.mux, CycloneV::bmux_type_t(o.s)); break;
    case CycloneV::MT_NUM:  dst->opt_n_set(o.mux, o.s); break;
    case CycloneV::MT_BOOL: dst->opt_b_set(o.mux, o.s); break;
    case CycloneV::MT_RAM:  dst->opt_r_set(o.mux, o.r); break;
    }
  }
}

static std::string pad_name(const CycloneV *m, CycloneV::xycoords pos, int idx)
{
  auto pin = m->pin_find_pos(pos, idx);
  char buf[64];
  snprintf(buf, sizeof buf, "GPIO.%03d.%03d.%d", pos.x(), pos.y(), idx);
  return std::string(buf) + " (" + (pin ? pin->name : "no pin") + ")";
}

// Give every GPIO pad the design configures the reference core's DRIVE_STRENGTH for that pad.
static void copy_io_standards(const CycloneV *ref, CycloneV *design)
{
  std::set<std::pair<uint32_t, int>> used;
  for(const auto &s : design->bmux_get())
    if(s.btype == CycloneV::GPIO && !s.def)
      used.insert({s.pos.v, s.midx});

  std::map<std::pair<uint32_t, int>, uint32_t> ref_ds;
  for(const auto &s : ref->bmux_get())
    if(s.btype == CycloneV::GPIO && s.mux == CycloneV::DRIVE_STRENGTH && !s.def)
      ref_ds[{s.pos.v, s.midx}] = s.s;

  for(const auto &[pv, idx] : used) {
    CycloneV::xycoords pos(pv);
    CycloneV::bmux_setting_t cur;
    design->bmux_get(CycloneV::GPIO, pos, CycloneV::DRIVE_STRENGTH, idx, cur);
    auto r = ref_ds.find({pv, idx});
    if(r == ref_ds.end()) {
      printf("io : %s has no DRIVE_STRENGTH in the reference core, left at %s\n", pad_name(design, pos, idx).c_str(),
             CycloneV::bmux_type_names[cur.s]);
      continue;
    }
    if(cur.s != r->second)
      printf("io : %s DRIVE_STRENGTH %s -> %s\n", pad_name(design, pos, idx).c_str(), CycloneV::bmux_type_names[cur.s],
             CycloneV::bmux_type_names[r->second]);
    design->bmux_m_set(CycloneV::GPIO, pos, CycloneV::DRIVE_STRENGTH, idx, CycloneV::bmux_type_t(r->second));
  }
}

static int count_design_diffs(const CycloneV *a, const CycloneV *b)
{
  int diffs = 0;
  auto ba = a->bmux_get(), bb = b->bmux_get();
  if(ba.size() != bb.size())
    diffs++;
  else
    for(size_t i = 0; i != ba.size(); i++)
      if(ba[i].btype != bb[i].btype || ba[i].pos != bb[i].pos || ba[i].mux != bb[i].mux || ba[i].midx != bb[i].midx ||
         ba[i].s != bb[i].s || ba[i].r != bb[i].r)
        diffs++;
  if(a->route_all_active_links() != b->route_all_active_links())
    diffs++;
  auto ia = a->inv_get(), ib = b->inv_get();
  if(ia.size() != ib.size())
    diffs++;
  else
    for(size_t i = 0; i != ia.size(); i++)
      if(ia[i].node != ib[i].node || ia[i].value != ib[i].value)
        diffs++;
  auto oa = a->opt_get(), ob = b->opt_get();
  for(size_t i = 0; i != oa.size(); i++)
    if(oa[i].s != ob[i].s || oa[i].r != ob[i].r)
      diffs++;
  return diffs;
}

int main(int argc, char **argv)
{
  std::string jtag_mode = "ref";
  bool keep_io = false;
  std::vector<const char *> pos;
  for(int i = 1; i != argc; i++) {
    if(!strcmp(argv[i], "--jtag-id") && i + 1 != argc)
      jtag_mode = argv[++i];
    else if(!strcmp(argv[i], "--keep-io"))
      keep_io = true;
    else if(argv[i][0] == '-') {
      fprintf(stderr, "unknown option %s\n", argv[i]);
      return 1;
    } else
      pos.push_back(argv[i]);
  }
  if(pos.size() != 4) {
    fprintf(stderr, "usage: %s model in.rbf ref.rbf out.cor [--jtag-id ref|sum|keep|<hex>] [--keep-io]\n", argv[0]);
    return 1;
  }

  auto in = load(pos[1]);
  auto ref = load(pos[2]);

  CycloneV *design = CycloneV::get_model(pos[0]);
  CycloneV *refm = CycloneV::get_model(pos[0]);
  if(!design || !refm) { fprintf(stderr, "unknown model %s\n", pos[0]); return 1; }
  refm->rbf_load(ref.data(), ref.size());
  design->rbf_load(in.data(), in.size());

  CycloneV::opt_setting_t comp;
  design->opt_get(CycloneV::COMPRESSION_DIS, comp);
  uint32_t in_jtag = get_r64(design, CycloneV::JTAG_ID);
  printf("in : JTAG_ID %08x OPT_B %016llx %s, %zu bytes\n", in_jtag,
         (unsigned long long)get_r64(design, CycloneV::OPT_B), comp.s ? "uncompressed" : "compressed", in.size());
  printf("ref: JTAG_ID %08x OPT_B %016llx, %zu bytes\n", uint32_t(get_r64(refm, CycloneV::JTAG_ID)),
         (unsigned long long)get_r64(refm, CycloneV::OPT_B), ref.size());

  copy_options(refm, design);
  design->opt_b_set(CycloneV::COMPRESSION_DIS, true);

  uint32_t jtag;
  if(jtag_mode == "ref")
    jtag = get_r64(refm, CycloneV::JTAG_ID);
  else if(jtag_mode == "sum")
    jtag = design->compute_default_jtag_id();
  else if(jtag_mode == "keep")
    jtag = in_jtag;
  else
    jtag = strtoul(jtag_mode.c_str(), nullptr, 16);
  design->opt_r_set(CycloneV::JTAG_ID, jtag);

  if(!keep_io)
    copy_io_standards(refm, design);

  std::vector<uint8_t> out;
  design->rbf_save(out);
  if(out.size() != ref.size())
    fprintf(stderr, "warning: output is %zu bytes, reference is %zu\n", out.size(), ref.size());

  const size_t ORAM = 628; // option frame
  size_t odiff = 0;
  for(size_t i = 0; i != ORAM && i < ref.size() && i < out.size(); i++)
    odiff += out[i] != ref[i];
  printf("out: JTAG_ID %08x OPT_B %016llx uncompressed, %zu bytes; option frame differs from ref in %zu bytes\n", jtag,
         (unsigned long long)get_r64(design, CycloneV::OPT_B), out.size(), odiff);

  CycloneV *check = CycloneV::get_model(pos[0]);
  check->rbf_load(out.data(), out.size());
  int diffs = count_design_diffs(design, check);
  std::vector<uint8_t> out2;
  check->rbf_save(out2);
  if(out2 != out)
    diffs++;
  printf("round trip: %d differences\n", diffs);
  if(diffs)
    return 3;

  for(auto &b : out)
    b = rev8(b);
  FILE *f = fopen(pos[3], "wb");
  if(!f) { perror(pos[3]); return 2; }
  fwrite(out.data(), 1, out.size(), f);
  fclose(f);
  printf("wrote %s\n", pos[3]);
  return 0;
}
