// Load a Cyclone V .rbf with libmistral and save it again, uncompressed.
// Usage: rbfcycle model in.rbf out.rbf
#include "cyclonev.h"
#include <cstdio>
#include <vector>

int main(int argc, char **argv)
{
  if(argc != 4) { fprintf(stderr, "usage: %s model in.rbf out.rbf\n", argv[0]); return 1; }
  auto model = mistral::CycloneV::get_model(argv[1]);
  if(!model) { fprintf(stderr, "unknown model %s\n", argv[1]); return 1; }
  FILE *f = fopen(argv[2], "rb");
  fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
  std::vector<uint8_t> in(n);
  fread(in.data(), 1, n, f); fclose(f);
  model->rbf_load(in.data(), n);
  model->opt_b_set(mistral::CycloneV::COMPRESSION_DIS, true);
  std::vector<uint8_t> out;
  model->rbf_save(out);
  f = fopen(argv[3], "wb"); fwrite(out.data(), 1, out.size(), f); fclose(f);
  return 0;
}
