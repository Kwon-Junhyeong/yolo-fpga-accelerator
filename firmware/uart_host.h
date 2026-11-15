#ifndef UART_HOST_H
#define UART_HOST_H

#include <stdint.h>

#define YOLO_UART_BASE          0x40600000u
#define YOLO_UART_BAUD          115200u
#define YOLO_CORE_CLOCK_HZ      81247969u

void uart_init(void);
void uart_putc(char c);
void uart_puts(const char *s);
void uart_put_hex32(uint32_t value);
int uart_getc_nonblock(void);
int uart_line_poll(char *line, uint32_t *line_len, uint32_t line_cap);

#endif
