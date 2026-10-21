// Print package/pin facts from mistral's Cyclone V database.
//   cvinfo pins MODEL       pin name, GPIO block/index, datasheet function, I/O bank
//   cvinfo pllin MODEL      which pins feed each fPLL's dedicated CLKIN inputs
#include "cyclonev.h"
#include <cstdio>
#include <cstring>

using mistral::CycloneV;

int main(int argc, char **argv)
{
  if(argc != 3) {
    fprintf(stderr, "usage: %s pins|pllin MODEL\n", argv[0]);
    return 1;
  }
  auto model = CycloneV::get_model(argv[2]);
  if(!model) {
    fprintf(stderr, "unknown model %s\n", argv[2]);
    return 1;
  }
  if(!strcmp(argv[1], "pins")) {
    for(int x = 0; x != 128; x++)
      for(int y = 0; y != 128; y++)
        for(int idx = 0; idx != 4; idx++) {
          auto p = model->pin_find_pos(CycloneV::xycoords(x, y), idx);
          if(p)
            printf("%-5s GPIO.%03d.%03d.%d %-28s %s\n", p->name, x, y, idx,
                   p->function ? p->function : "", p->io_block ? p->io_block : "");
        }
  } else if(!strcmp(argv[1], "pllin")) {
    for(const auto &e : model->get_all_p2p()) {
      for(auto pn : { e.first, e.second }) {
        auto other = pn == e.first ? e.second : e.first;
        if(pn.bt() != CycloneV::FPLL || other.bt() != CycloneV::GPIO)
          continue;
        auto pin = model->pin_find_pnode(other);
        printf("%s <- %s %s %s\n", pn.to_string().c_str(), other.to_string().c_str(),
               pin ? pin->name : "?", pin && pin->function ? pin->function : "");
      }
    }
  }
  delete model;
  return 0;
}
