#ifndef YOLO_HW_FORWARD_H
#define YOLO_HW_FORWARD_H

#include <stdint.h>

#define YOLO_REG_BASE          0x44A00000u
#define YOLO_DDR_BASE          0x80000000u

#define YOLO_ACCEL_INPUT_OFF   0x00000000u
#define YOLO_ACCEL_O14_OFF     4915072u
#define YOLO_ACCEL_O20_OFF     4964992u

#define YOLO_STAGE_INPUT_OFF   0x01000000u
#define YOLO_STAGE_W06_OFF     0x01100000u
#define YOLO_STAGE_W08_OFF     0x01120000u
#define YOLO_STAGE_W10_OFF     0x01180000u
#define YOLO_STAGE_W12_OFF     0x01300000u
#define YOLO_STAGE_W13_OFF     0x01360000u
#define YOLO_STAGE_W14_OFF     0x014E0000u
#define YOLO_STAGE_W17_OFF     0x01530000u
#define YOLO_STAGE_W20_OFF     0x01550000u
#define YOLO_STAGE_O14_OFF     0x01600000u
#define YOLO_STAGE_O20_OFF     0x01610000u

#define YOLO_MAILBOX_OFF       0x007F0000u
#define YOLO_MAILBOX_WORDS     16u

#define YOLO_INPUT_WORDS       65536u
#define YOLO_O14_WORDS         12480u
#define YOLO_O20_WORDS         49920u

#define YOLO_STATUS_READY      0xC0DE0001u
#define YOLO_STATUS_BUSY       0xC0DE5101u
#define YOLO_STATUS_DONE       0xC0DE600Du
#define YOLO_STATUS_FAIL       0xC0DEFA11u
#define YOLO_CMD_RUN           0x594F4C4Fu

#define YOLO_FLAG_RELOAD_WEIGHTS 0x00000001u

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

void yolo_hw_init(yolo_hw_t *hw);
void yolo_hw_forget_weights(yolo_hw_t *hw);
int yolo_hw_bootload_weights_once(yolo_hw_t *hw);
int yolo_hw_forward(yolo_hw_t *hw, yolo_hw_result_t *result);
void yolo_delay_cycles(volatile uint32_t cycles);

#endif
