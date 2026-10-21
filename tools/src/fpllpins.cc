// List the package pins that can feed each fPLL's reference inputs (fixed p2p links
// FPLL:CLKIN.n <- GPIO:COMBOUT, FPLL:EXTCLK.n <-> GPIO:PLLDIN). See notes/toolchain.md,
// "Reference clock pin". Usage: fpllpins [model]   (default 5CEBA4F23C8)
// (mistral-cv's own "p2p" dump is garbled in mistral d509238, hence this.)
#include "cyclonev.h"
#include <cstdio>

using C = mistral::CycloneV;

int main(int argc, char **argv)
{
  auto m = C::get_model(argc > 1 ? argv[1] : "5CEBA4F23C8");
  if(!m) { fprintf(stderr, "unknown model\n"); return 1; }
  for(auto pos : m->fpll_get_pos()) {
    printf("FPLL.%03d.%03d\n", pos.x(), pos.y());
    for(auto port : {C::CLKIN, C::EXTCLK})
      for(int i = 0; i < 4; i++) {
        C::pnode_coords pn(C::FPLL, pos, port, -1, i);
        auto v = m->p2p_from(pn);
        if(auto t = m->p2p_to(pn))
          v.push_back(t);
        for(auto s : v) {
          auto pin = m->pin_find_pnode(s);
          printf("  %-24s %-26s pin %s\n", pn.to_string().c_str(), s.to_string().c_str(), pin ? pin->name : "-");
        }
      }
  }
  return 0;
}
