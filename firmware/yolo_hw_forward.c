#include "yolo_hw_forward.h"

#define YOLO_REG0       (*(volatile uint32_t *)(YOLO_REG_BASE + 0x00u))
#define YOLO_REG1       (*(volatile uint32_t *)(YOLO_REG_BASE + 0x04u))
#define YOLO_REG2       (*(volatile uint32_t *)(YOLO_REG_BASE + 0x08u))
#define YOLO_REG3       (*(volatile uint32_t *)(YOLO_REG_BASE + 0x0Cu))
#define YOLO_CYCLES     (*(volatile uint32_t *)(YOLO_REG_BASE + 0x10u))
#define YOLO_POST_DONE_DRAIN_CYCLES 1048576u

typedef struct {
    uint32_t stage_off;
    uint32_t accel_off;
    uint32_t words;
} yolo_region_t;

static const yolo_region_t weight_regions[] = {
    { YOLO_STAGE_W06_OFF, 262144u, 24576u },
    { YOLO_STAGE_W08_OFF, 360448u, 98304u },
    { YOLO_STAGE_W10_OFF, 753664u, 393216u },
    { YOLO_STAGE_W12_OFF, 2326528u, 98304u },
    { YOLO_STAGE_W13_OFF, 2719744u, 393216u },
    { YOLO_STAGE_W14_OFF, 4292608u, 74880u },
    { YOLO_STAGE_W17_OFF, 4592128u, 24576u },
    { YOLO_STAGE_W20_OFF, 4690432u, 56160u },
};

void yolo_delay_cycles(volatile uint32_t cycles)
{
    while (cycles--) {
        __asm__ volatile ("nop");
    }
}

static volatile uint32_t *ddr_words(uint32_t byte_off)
{
    return (volatile uint32_t *)(YOLO_DDR_BASE + byte_off);
}

static uint32_t ddr_read_word(uint32_t byte_off)
{
    return *ddr_words(byte_off);
}

static void copy_words(uint32_t dst_byte_off, uint32_t src_byte_off, uint32_t words)
{
    volatile uint32_t *dst = ddr_words(dst_byte_off);
    volatile const uint32_t *src = (volatile const uint32_t *)ddr_words(src_byte_off);

    for (uint32_t i = 0; i < words; i++) {
        dst[i] = src[i];
    }
}

static void fill_words(uint32_t dst_byte_off, uint32_t words, uint32_t value)
{
    volatile uint32_t *dst = ddr_words(dst_byte_off);

    for (uint32_t i = 0; i < words; i++) {
        dst[i] = value;
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
    if (hw->weights_loaded != 0u) {
        return 0;
    }

    for (uint32_t i = 0; i < (uint32_t)(sizeof(weight_regions) / sizeof(weight_regions[0])); i++) {
        copy_words(weight_regions[i].accel_off, weight_regions[i].stage_off, weight_regions[i].words);
    }

    hw->weights_loaded = 1u;
    return 0;
}

int yolo_hw_forward(yolo_hw_t *hw, yolo_hw_result_t *result)
{
    uint32_t polls = 0u;

    if (result != 0) {
        result->reg0 = 0u;
        result->cycles = 0u;
        result->polls = 0u;
        result->first_l14_word = 0u;
        result->first_l20_word = 0u;
    }

    yolo_hw_bootload_weights_once(hw);

    copy_words(YOLO_ACCEL_INPUT_OFF, YOLO_STAGE_INPUT_OFF, YOLO_INPUT_WORDS);
    fill_words(YOLO_ACCEL_O14_OFF, YOLO_O14_WORDS, 0xDEADBEEFu);
    fill_words(YOLO_ACCEL_O20_OFF, YOLO_O20_WORDS, 0xDEADBEEFu);
    fill_words(YOLO_STAGE_O14_OFF, YOLO_O14_WORDS, 0xDEADBEEFu);
    fill_words(YOLO_STAGE_O20_OFF, YOLO_O20_WORDS, 0xDEADBEEFu);

    YOLO_REG0 = 0x00000004u;
    yolo_delay_cycles(1024u);
    YOLO_REG0 = 0x00000000u;
    yolo_delay_cycles(1024u);

    YOLO_REG1 = 0x00000000u;
    YOLO_REG2 = 0x00000000u;
    YOLO_REG3 = 0x00000000u;

    YOLO_REG0 = 0x00000001u;
    yolo_delay_cycles(64u);
    YOLO_REG0 = 0x00000000u;

    while (((YOLO_REG0 >> 1) & 1u) == 0u && polls < hw->poll_limit) {
        polls++;
    }

    if (result != 0) {
        result->reg0 = YOLO_REG0;
        result->cycles = YOLO_CYCLES;
        result->polls = polls;
    }

    if (((YOLO_REG0 >> 1) & 1u) == 0u) {
        return -1;
    }

    yolo_delay_cycles(YOLO_POST_DONE_DRAIN_CYCLES);

    copy_words(YOLO_STAGE_O14_OFF, YOLO_ACCEL_O14_OFF, YOLO_O14_WORDS);
    copy_words(YOLO_STAGE_O20_OFF, YOLO_ACCEL_O20_OFF, YOLO_O20_WORDS);

    if (result != 0) {
        result->first_l14_word = ddr_read_word(YOLO_STAGE_O14_OFF);
        result->first_l20_word = ddr_read_word(YOLO_STAGE_O20_OFF);
    }

    return 0;
}
