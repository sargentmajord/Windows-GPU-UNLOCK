/* Host check for the firmware-boot assessment. Includes upstream issue 42: register-error values (0xbadfxxxx) must not count
 * as a completed firmware boot. No GPU access. */
#include <stdio.h>
#include <errno.h>
#include "../vendor/gfw_eval.h"
static int failures;
#define CHECK(c) do { if (!(c)) { printf("FAIL %s (line %d)\n", #c, __LINE__); failures++; } } while (0)
int main(void) {
  struct gpu_unlock_gfw_sample ok = {.config_ok = true, .plm = 0x8b8f, .boot = 0x3ff, .cpuctl = 0x10};  /* this machine's cold values */
  CHECK(gpu_unlock_gfw_assess(&ok) == 0);
  CHECK(gpu_unlock_gfw_assess(NULL) == -ENODEV);
  struct gpu_unlock_gfw_sample s = ok; s.config_ok = false; CHECK(gpu_unlock_gfw_assess(&s) == -ENODEV);
  s = ok; s.plm = ~0U; CHECK(gpu_unlock_gfw_assess(&s) == -ENODEV);
  s = ok; s.boot = ~0U; CHECK(gpu_unlock_gfw_assess(&s) == -ENODEV);
  s = ok; s.cpuctl = ~0U; CHECK(gpu_unlock_gfw_assess(&s) == -ENODEV);
  /* upstream issue 42 reproduction, then each field alone */
  s = (struct gpu_unlock_gfw_sample){.config_ok = true, .plm = 0xbadf0001, .boot = 0xbadf00ff, .cpuctl = 0xbadf0010};
  CHECK(gpu_unlock_gfw_assess(&s) == -ENODEV);
  s = ok; s.plm = 0xbadf0001; CHECK(gpu_unlock_gfw_assess(&s) == -ENODEV);
  s = ok; s.boot = 0xbadf00ff; CHECK(gpu_unlock_gfw_assess(&s) == -ENODEV);
  s = ok; s.cpuctl = 0xbadf0010; CHECK(gpu_unlock_gfw_assess(&s) == -ENODEV);
  s = ok; s.cpuctl = 0x0; CHECK(gpu_unlock_gfw_assess(&s) == -EAGAIN);      /* still running */
  s = ok; s.plm = 0x8b8e; CHECK(gpu_unlock_gfw_assess(&s) == -EAGAIN);      /* level-0 bit clear */
  s = ok; s.boot = 0x3fe; CHECK(gpu_unlock_gfw_assess(&s) == -EAGAIN);      /* not completed */
  if (failures) { printf("%d check(s) failed\n", failures); return 1; }
  puts("PASS firmware-boot assessment, including register-error values");
  return 0;
}
