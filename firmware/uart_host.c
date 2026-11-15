#include "uart_host.h"

#define UART_RX_FIFO    (*(volatile uint32_t *)(YOLO_UART_BASE + 0x00u))
#define UART_TX_FIFO    (*(volatile uint32_t *)(YOLO_UART_BASE + 0x04u))
#define UART_STATUS     (*(volatile uint32_t *)(YOLO_UART_BASE + 0x08u))
#define UART_CONTROL    (*(volatile uint32_t *)(YOLO_UART_BASE + 0x0Cu))

#define UART_SR_RX_VALID 0x01u
#define UART_SR_TX_FULL  0x08u
#define UART_CR_RST_TX   0x01u
#define UART_CR_RST_RX   0x02u

void uart_init(void)
{
    UART_CONTROL = UART_CR_RST_TX | UART_CR_RST_RX;
    UART_CONTROL = 0u;
}

void uart_putc(char c)
{
    while ((UART_STATUS & UART_SR_TX_FULL) != 0u) {
    }
    UART_TX_FIFO = (uint32_t)(uint8_t)c;
}

void uart_puts(const char *s)
{
    while (*s != '\0') {
        uart_putc(*s++);
    }
}

void uart_put_hex32(uint32_t value)
{
    static const char hex[] = "0123456789ABCDEF";

    uart_puts("0x");
    for (int shift = 28; shift >= 0; shift -= 4) {
        uart_putc(hex[(value >> (uint32_t)shift) & 0xFu]);
    }
}

int uart_getc_nonblock(void)
{
    if ((UART_STATUS & UART_SR_RX_VALID) == 0u) {
        return -1;
    }

    return (int)(UART_RX_FIFO & 0xFFu);
}

int uart_line_poll(char *line, uint32_t *line_len, uint32_t line_cap)
{
    int got_line = 0;

    while ((UART_STATUS & UART_SR_RX_VALID) != 0u) {
        int ch = uart_getc_nonblock();

        if (ch < 0) {
            break;
        }

        if (ch == '\r') {
            continue;
        }

        if (ch == '\n') {
            line[*line_len] = '\0';
            *line_len = 0u;
            got_line = 1;
            break;
        }

        if (ch == 8 || ch == 127) {
            if (*line_len != 0u) {
                (*line_len)--;
            }
            continue;
        }

        if (*line_len + 1u < line_cap) {
            line[*line_len] = (char)ch;
            (*line_len)++;
        }
    }

    return got_line;
}
