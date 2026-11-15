#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../yolo_hw_forward.h"

#define DDR_SIZE 0x01700000u
#define FAKE_CYCLES 7866198u
#define DONE_AFTER_POLLS 1000u

static uint32_t *ddr;
static uint32_t csr[8];
static uint32_t csr_log_off[64], csr_log_val[64];
static unsigned csr_log_n;
static unsigned polls_seen;
static int running;
static unsigned weight_copies;
static int failures;

static void check(int ok, const char *what)
{
    printf("%s %s\n", ok ? "PASS" : "FAIL", what);
    if (!ok) failures++;
}

static uint32_t *ddr_word(uint32_t addr)
{
    uint32_t off = addr - YOLO_DDR_BASE;
    if (addr < YOLO_DDR_BASE || off >= DDR_SIZE) {
        fprintf(stderr, "access outside DDR model: 0x%08x\n", addr);
        exit(2);
    }
    return &ddr[off / 4u];
}

static void accelerator_run(void)
{
    uint32_t i;
    for (i = 0; i < YOLO_ACC_O14_WORDS; i++) ddr[(YOLO_ACC_O14_OFF / 4u) + i] = 0x14000000u + i;
    for (i = 0; i < YOLO_ACC_O20_WORDS; i++) ddr[(YOLO_ACC_O20_OFF / 4u) + i] = 0x20000000u + i;
    csr[4] = FAKE_CYCLES;
}

uint32_t yolo_test_read(uint32_t addr)
{
    if (addr >= YOLO_CSR_BASE && addr < YOLO_CSR_BASE + 0x20u) {
        uint32_t idx = (addr - YOLO_CSR_BASE) / 4u;
        if (idx == 0u && running) {
            if (++polls_seen >= DONE_AFTER_POLLS) {
                running = 0;
                accelerator_run();
                csr[0] |= YOLO_CTRL_DONE;
            }
        }
        return csr[idx];
    }
    return *ddr_word(addr);
}

void yolo_test_write(uint32_t addr, uint32_t value)
{
    if (addr >= YOLO_CSR_BASE && addr < YOLO_CSR_BASE + 0x20u) {
        uint32_t idx = (addr - YOLO_CSR_BASE) / 4u;
        if (csr_log_n < 64u) {
            csr_log_off[csr_log_n] = addr - YOLO_CSR_BASE;
            csr_log_val[csr_log_n] = value;
            csr_log_n++;
        }
        if (idx == 0u) {
            if ((value & YOLO_CTRL_SOFT_RESET) != 0u) csr[0] = 0u;
            if ((value & YOLO_CTRL_START) != 0u && !(csr[0] & YOLO_CTRL_START)) {
                running = 1;
                polls_seen = 0;
                csr[0] &= ~YOLO_CTRL_DONE;
            }
            csr[0] = (csr[0] & YOLO_CTRL_DONE) | (value & ~YOLO_CTRL_DONE);
        } else {
            csr[idx] = value;
        }
        return;
    }
    if (addr - YOLO_DDR_BASE == 0x00040000u) weight_copies++;
    *ddr_word(addr) = value;
}

int main(void)
{
    static const uint32_t expect_off[] = {0x00, 0x00, 0x04, 0x08, 0x0C, 0x00, 0x00};
    static const uint32_t expect_val[] = {YOLO_CTRL_SOFT_RESET, 0, 0, 0, 0, YOLO_CTRL_START, 0};
    yolo_hw_t hw;
    yolo_hw_result_t r;
    uint32_t i;
    int ok;

    ddr = calloc(DDR_SIZE / 4u, sizeof(uint32_t));
    if (!ddr) return 2;
    for (i = 0; i < YOLO_ACC_INPUT_WORDS; i++) ddr[(YOLO_STAGE_INPUT_OFF / 4u) + i] = 0x00A00000u + i;
    ddr[0x01100000u / 4u] = 0x06060606u;
    ddr[0x01550000u / 4u + 56159u] = 0x20202020u;

    yolo_hw_init(&hw);
    check(yolo_hw_forward(&hw, &r) == 0, "forward returns 0 when the done bit is set");

    ok = csr_log_n == 7u;
    for (i = 0; ok && i < 7u; i++) ok = csr_log_off[i] == expect_off[i] && csr_log_val[i] == expect_val[i];
    check(ok, "register writes: soft reset, clear, read base, write base, config, start, clear");
    check(ddr[YOLO_ACC_INPUT_OFF / 4u] == 0x00A00000u && ddr[YOLO_ACC_INPUT_OFF / 4u + 65535u] == 0x00A0FFFFu,
          "input image copied from the staging window to the accelerator's input");
    check(ddr[0x00040000u / 4u] == 0x06060606u && ddr[0x00479200u / 4u + 56159u] == 0x20202020u,
          "weights of layers 6 and 20 copied to the addresses in rtl/cnn_ctrl_v2.v");
    check(ddr[YOLO_STAGE_O14_OFF / 4u + 12479u] == 0x14000000u + 12479u &&
          ddr[YOLO_STAGE_O20_OFF / 4u + 49919u] == 0x20000000u + 49919u,
          "L14 and L20 outputs copied to the staging windows the JTAG batch reads");
    check(r.cycles == FAKE_CYCLES && r.polls == DONE_AFTER_POLLS - 1u && (r.reg0 & YOLO_CTRL_DONE),
          "result holds the cycle register, the poll count and reg0");
    check(r.first_l14_word == 0x14000000u && r.first_l20_word == 0x20000000u, "result holds the first output words");

    weight_copies = 0;
    csr_log_n = 0;
    yolo_hw_forward(&hw, &r);
    check(weight_copies == 0u, "weights are not copied again on the next frame");
    yolo_hw_forget_weights(&hw);
    yolo_hw_forward(&hw, &r);
    check(weight_copies == 1u, "weights are copied again after yolo_hw_forget_weights");

    hw.poll_limit = 10u;
    check(yolo_hw_forward(&hw, &r) == -1 && (r.reg0 & YOLO_CTRL_DONE) == 0u,
          "forward returns -1 when the done bit does not come within the poll limit");

    printf("%d failures\n", failures);
    free(ddr);
    return failures != 0;
}
