// Dump the fixed fPLL/clock-mux wiring of a Cyclone V model from mistral's database, as text for
// tools/pllpatch.py (notes/pll.md). Usage: pllinfo [MODEL]   (default 5CEBA4F23C8)
//
// Output lines:
//   clkin FPLL.x.y n PIN GPIO.x.y.i      fPLL dedicated reference input CLKIN.n <- package pin
//   out FPLL.x.y n CMUXxx.x.y m          fPLL output PLLCOUT.n -> clock mux input PLLIN.m
//   sel CMUXxx z VALUE KIND idx          clock mux z: INPUT_SEL = VALUE (hex) selects KIND.idx
#include "cyclonev.h"
#include <cstdio>

using C = mistral::CycloneV;

static void dump_sel(const char *name, const std::pair<uint8_t, uint8_t> *tab, int nz, int nv)
{
  for(int z = 0; z != nz; z++)
    for(int v = 0; v != nv; v++) {
      auto e = tab[z * nv + v];
      if(e.first == C::CMUX_OFF && v > 0x23)
        continue;
      printf("sel %s %d %02x %s %d\n", name, z, v, C::cmux_link_names[e.first], e.second);
    }
}

int main(int argc, char **argv)
{
  auto m = C::get_model(argc > 1 ? argv[1] : "5CEBA4F23C8");
  if(!m) { fprintf(stderr, "unknown model\n"); return 1; }

  for(const auto &e : m->get_all_p2p()) {
    for(int dir = 0; dir != 2; dir++) {
      auto a = dir ? e.second : e.first;
      auto b = dir ? e.first : e.second;
      if(a.bt() != C::FPLL)
        continue;
      if(a.pt() == C::CLKIN && b.bt() == C::GPIO) {
        auto pin = m->pin_find_pnode(b);
        printf("clkin FPLL.%03d.%03d %d %s GPIO.%03d.%03d.%d\n", a.x(), a.y(), a.pi(),
               pin ? pin->name : "-", b.x(), b.y(), b.bi());
      }
      if(a.pt() == C::PLLCOUT && (b.bt() == C::CMUXHG || b.bt() == C::CMUXVG || b.bt() == C::CMUXHR ||
                                  b.bt() == C::CMUXVR || b.bt() == C::CMUXCR) && b.pt() == C::PLLIN)
        printf("out FPLL.%03d.%03d %d %s.%03d.%03d %d\n", a.x(), a.y(), a.pi(),
               C::block_type_names[b.bt()], b.x(), b.y(), b.pi());
    }
  }

  dump_sel("CMUXHG", &C::cmuxhg_link_table[0][0], 4, 64);
  dump_sel("CMUXVG", &C::cmuxvg_link_table[0][0], 4, 64);
  dump_sel("CMUXCR", &C::cmuxcr_link_table[0][0], 6, 16);
  dump_sel("CMUXHR", &C::cmuxhr_link_table[0][0], 12, 32);
  dump_sel("CMUXVR", &C::cmuxvr_link_table[0][0], 20, 16);
  delete m;
  return 0;
}
