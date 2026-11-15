#ifndef YOLO_HW_FORWARD_FW_H
#define YOLO_HW_FORWARD_FW_H

#include <stdint.h>

#define YOLO_DDR_BASE           0x80000000u
#define YOLO_CSR_BASE           0x44A00000u

#define YOLO_CSR_CTRL           0x00u
#define YOLO_CSR_RD_BASE        0x04u
#define YOLO_CSR_WR_BASE        0x08u
#define YOLO_CSR_CONFIG         0x0Cu
#define YOLO_CSR_CYCLES         0x10u
#define YOLO_CTRL_START         0x1u
#define YOLO_CTRL_DONE          0x2u
#define YOLO_CTRL_SOFT_RESET    0x4u

#define YOLO_ACC_INPUT_OFF      0x00000000u
#define YOLO_ACC_INPUT_WORDS    65536u
#define YOLO_ACC_O14_OFF        0x004AFF80u
#define YOLO_ACC_O14_WORDS      12480u
#define YOLO_ACC_O20_OFF        0x004BC280u
#define YOLO_ACC_O20_WORDS      49920u

#define YOLO_MAILBOX_OFF        0x007F0000u
#define YOLO_STAGE_INPUT_OFF    0x01000000u
#define YOLO_STAGE_O14_OFF      0x01600000u
#define YOLO_STAGE_O20_OFF      0x01610000u

#define YOLO_CMD_RUN            0x594F4C4Fu
#define YOLO_STATUS_READY       0xC0DE0001u
#define YOLO_STATUS_BUSY        0xC0DE5101u
#define YOLO_STATUS_DONE        0xC0DE600Du
#define YOLO_STATUS_FAIL        0xC0DEFA11u
#define YOLO_FLAG_RELOAD_WEIGHTS 0x1u

#define YOLO_UNWRITTEN          0xDEADBEEFu

typedef struct {
    uint32_t weights_loaded;
    uint32_t poll_limit;
} yolo_hw_t;

typedef struct {
    uint32_t reg0;
    uint32_t cycles;
    uint32_t polls;
    uint32_t first_l14_word;
    uint32_t first_l20_word;
} yolo_hw_result_t;

typedef struct {
    uint32_t stage_off;
    uint32_t accel_off;
    uint32_t words;
} yolo_region_t;

void yolo_delay_cycles(uint32_t n);
void yolo_hw_init(yolo_hw_t *hw);
void yolo_hw_forget_weights(yolo_hw_t *hw);
int yolo_hw_bootload_weights_once(yolo_hw_t *hw);
int yolo_hw_forward(yolo_hw_t *hw, yolo_hw_result_t *result);

#endif
