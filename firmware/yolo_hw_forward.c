#include "yolo_hw_forward.h"

#ifdef YOLO_HW_HOST_TEST
uint32_t yolo_test_read(uint32_t addr);
void yolo_test_write(uint32_t addr, uint32_t value);
#define YOLO_RD(addr)        yolo_test_read(addr)
#define YOLO_WR(addr, value) yolo_test_write((addr), (value))
#else
#define YOLO_RD(addr)        (*(volatile uint32_t *)(uintptr_t)(addr))
#define YOLO_WR(addr, value) (*(volatile uint32_t *)(uintptr_t)(addr) = (value))
#endif

#define CSR(off) (YOLO_CSR_BASE + (off))

static const yolo_region_t weight_regions[8] = {
    {0x01100000u, 0x00040000u,  24576u},
    {0x01120000u, 0x00058000u,  98304u},
    {0x01180000u, 0x000B8000u, 393216u},
    {0x01300000u, 0x00238000u,  98304u},
    {0x01360000u, 0x00298000u, 393216u},
    {0x014E0000u, 0x00418000u,  74880u},
    {0x01530000u, 0x00461200u,  24576u},
    {0x01550000u, 0x00479200u,  56160u},
};

static uint32_t ddr_addr(uint32_t off)
{
    return YOLO_DDR_BASE + off;
}

static void copy_words(uint32_t dst_off, uint32_t src_off, uint32_t words)
{
    uint32_t i;
    for (i = 0; i < words; i++) {
        YOLO_WR(ddr_addr(dst_off) + 4u * i, YOLO_RD(ddr_addr(src_off) + 4u * i));
    }
}

static void fill_words(uint32_t dst_off, uint32_t words, uint32_t value)
{
    uint32_t i;
    for (i = 0; i < words; i++) {
        YOLO_WR(ddr_addr(dst_off) + 4u * i, value);
    }
}

void yolo_delay_cycles(uint32_t n)
{
    volatile uint32_t count = n;
    while (count-- != 0u) {
    }
}

void yolo_hw_init(yolo_hw_t *hw)
{
    hw->weights_loaded = 0u;
    hw->poll_limit = 0x10000000u;
}

void yolo_hw_forget_weights(yolo_hw_t *hw)
{
    hw->weights_loaded = 0u;
}

int yolo_hw_bootload_weights_once(yolo_hw_t *hw)
{
    uint32_t i;
    if (hw->weights_loaded != 0u) {
        return 0;
    }
    for (i = 0; i < 8u; i++) {
        copy_words(weight_regions[i].accel_off, weight_regions[i].stage_off, weight_regions[i].words);
    }
    hw->weights_loaded = 1u;
    return 0;
}

int yolo_hw_forward(yolo_hw_t *hw, yolo_hw_result_t *result)
{
    uint32_t polls = 0u;
    uint32_t reg0;

    if (result != 0) {
        result->reg0 = 0u;
        result->cycles = 0u;
        result->polls = 0u;
        result->first_l14_word = 0u;
        result->first_l20_word = 0u;
    }

    yolo_hw_bootload_weights_once(hw);
    copy_words(YOLO_ACC_INPUT_OFF, YOLO_STAGE_INPUT_OFF, YOLO_ACC_INPUT_WORDS);
    fill_words(YOLO_ACC_O14_OFF, YOLO_ACC_O14_WORDS, YOLO_UNWRITTEN);
    fill_words(YOLO_ACC_O20_OFF, YOLO_ACC_O20_WORDS, YOLO_UNWRITTEN);
    fill_words(YOLO_STAGE_O14_OFF, YOLO_ACC_O14_WORDS, YOLO_UNWRITTEN);
    fill_words(YOLO_STAGE_O20_OFF, YOLO_ACC_O20_WORDS, YOLO_UNWRITTEN);

    YOLO_WR(CSR(YOLO_CSR_CTRL), YOLO_CTRL_SOFT_RESET);
    yolo_delay_cycles(1024u);
    YOLO_WR(CSR(YOLO_CSR_CTRL), 0u);
    yolo_delay_cycles(1024u);
    YOLO_WR(CSR(YOLO_CSR_RD_BASE), 0u);
    YOLO_WR(CSR(YOLO_CSR_WR_BASE), 0u);
    YOLO_WR(CSR(YOLO_CSR_CONFIG), 0u);
    YOLO_WR(CSR(YOLO_CSR_CTRL), YOLO_CTRL_START);
    yolo_delay_cycles(64u);
    YOLO_WR(CSR(YOLO_CSR_CTRL), 0u);

    while ((YOLO_RD(CSR(YOLO_CSR_CTRL)) & YOLO_CTRL_DONE) == 0u && polls < hw->poll_limit) {
        polls++;
    }

    if (result != 0) {
        result->reg0 = YOLO_RD(CSR(YOLO_CSR_CTRL));
        result->cycles = YOLO_RD(CSR(YOLO_CSR_CYCLES));
        result->polls = polls;
    }

    reg0 = YOLO_RD(CSR(YOLO_CSR_CTRL));
    if ((reg0 & YOLO_CTRL_DONE) == 0u) {
        return -1;
    }

    yolo_delay_cycles(0x00100000u);
    copy_words(YOLO_STAGE_O14_OFF, YOLO_ACC_O14_OFF, YOLO_ACC_O14_WORDS);
    copy_words(YOLO_STAGE_O20_OFF, YOLO_ACC_O20_OFF, YOLO_ACC_O20_WORDS);

    if (result != 0) {
        result->first_l14_word = YOLO_RD(ddr_addr(YOLO_STAGE_O14_OFF));
        result->first_l20_word = YOLO_RD(ddr_addr(YOLO_STAGE_O20_OFF));
    }
    return 0;
}
