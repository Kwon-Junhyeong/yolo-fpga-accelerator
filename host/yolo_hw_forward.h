#ifndef YOLO_HW_FORWARD_H
#define YOLO_HW_FORWARD_H

#include "additionally.h"

typedef enum yolo_hw_backend {
    YOLO_HW_BACKEND_NONE = 0,
    YOLO_HW_BACKEND_SNAPSHOT = 1,
    YOLO_HW_BACKEND_JTAG = 2,
    YOLO_HW_BACKEND_UART = 3
} yolo_hw_backend;

int yolo_hw_forward_enabled(void);
yolo_hw_backend yolo_hw_forward_backend(void);
const char *yolo_hw_forward_backend_name(yolo_hw_backend backend);

int yolo_hw_forward_from_head16_files(network net,
                                      const char *l14_path,
                                      const char *l20_path);

int yolo_hw_forward_from_head32_partition_files(network net,
                                                const char *l14_path,
                                                const char *l20_path);

int yolo_hw_forward_if_requested(network net,
                                 float *input,
                                 const char *image_path,
                                 int image_index);

void yolo_hw_forward_reset_stats(void);
void yolo_hw_forward_print_stats(void);

#endif
