#include "yolo_hw_forward.h"
#include "uart_host.h"

enum {
    MBX_STATUS = 0,
    MBX_REQUEST_SEQ = 1,
    MBX_DONE_SEQ = 2,
    MBX_FLAGS = 3,
    MBX_CYCLES = 4,
    MBX_POLLS = 5,
    MBX_REG0 = 6,
    MBX_ERROR = 7,
    MBX_FIRST_L14 = 8,
    MBX_FIRST_L20 = 9,
    MBX_WEIGHTS_LOADED = 10,
    MBX_STAGE_INPUT = 11,
    MBX_STAGE_O14 = 12,
    MBX_STAGE_O20 = 13,
    MBX_RUN_COUNT = 14,
    MBX_RESERVED = 15
};

static volatile uint32_t * const mailbox = (volatile uint32_t *)(YOLO_DDR_BASE + YOLO_MAILBOX_OFF);

static void publish_static_mailbox_fields(const yolo_hw_t *hw, uint32_t run_count)
{
    mailbox[MBX_WEIGHTS_LOADED] = hw->weights_loaded;
    mailbox[MBX_STAGE_INPUT] = YOLO_STAGE_INPUT_OFF;
    mailbox[MBX_STAGE_O14] = YOLO_STAGE_O14_OFF;
    mailbox[MBX_STAGE_O20] = YOLO_STAGE_O20_OFF;
    mailbox[MBX_RUN_COUNT] = run_count;
    mailbox[MBX_RESERVED] = 0u;
}

static void publish_result_mailbox_fields(const yolo_hw_result_t *result)
{
    mailbox[MBX_CYCLES] = result->cycles;
    mailbox[MBX_POLLS] = result->polls;
    mailbox[MBX_REG0] = result->reg0;
    mailbox[MBX_FIRST_L14] = result->first_l14_word;
    mailbox[MBX_FIRST_L20] = result->first_l20_word;
}

static int run_forward_command(yolo_hw_t *hw, uint32_t flags, yolo_hw_result_t *result, uint32_t *run_count)
{
    int rc;

    if ((flags & YOLO_FLAG_RELOAD_WEIGHTS) != 0u) {
        yolo_hw_forget_weights(hw);
    }

    rc = yolo_hw_forward(hw, result);
    (*run_count)++;

    return rc;
}

static char ascii_upper(char ch)
{
    if (ch >= 'a' && ch <= 'z') {
        return (char)(ch - ('a' - 'A'));
    }

    return ch;
}

static const char *skip_spaces(const char *s)
{
    while (*s == ' ' || *s == '\t') {
        s++;
    }

    return s;
}

static int token_match(const char **cursor, const char *token)
{
    const char *s = skip_spaces(*cursor);
    const char *t = token;

    while (*t != '\0') {
        if (ascii_upper(*s) != *t) {
            return 0;
        }
        s++;
        t++;
    }

    if (*s != '\0' && *s != ' ' && *s != '\t') {
        return 0;
    }

    *cursor = s;
    return 1;
}

static int parse_u32(const char **cursor, uint32_t *value)
{
    const char *s = skip_spaces(*cursor);
    uint32_t base = 10u;
    uint32_t parsed = 0u;
    uint32_t digits = 0u;

    if (s[0] == '0' && ascii_upper(s[1]) == 'X') {
        base = 16u;
        s += 2;
    }

    while (*s != '\0' && *s != ' ' && *s != '\t') {
        char ch = ascii_upper(*s);
        uint32_t digit;

        if (ch >= '0' && ch <= '9') {
            digit = (uint32_t)(ch - '0');
        } else if (ch >= 'A' && ch <= 'F') {
            digit = (uint32_t)(ch - 'A') + 10u;
        } else {
            return 0;
        }

        if (digit >= base) {
            return 0;
        }

        parsed = parsed * base + digit;
        digits++;
        s++;
    }

    if (digits == 0u) {
        return 0;
    }

    *value = parsed;
    *cursor = s;
    return 1;
}

static void uart_put_field_hex(const char *name, uint32_t value)
{
    uart_putc(' ');
    uart_puts(name);
    uart_putc('=');
    uart_put_hex32(value);
}

static void uart_print_status(const yolo_hw_t *hw,
                              uint32_t run_count,
                              uint32_t last_uart_seq,
                              uint32_t last_rc,
                              const yolo_hw_result_t *last_result)
{
    uart_puts("STATUS");
    uart_put_field_hex("run_count", run_count);
    uart_put_field_hex("weights", hw->weights_loaded);
    uart_put_field_hex("uart_seq", last_uart_seq);
    uart_put_field_hex("last_rc", last_rc);
    uart_put_field_hex("cycles", last_result->cycles);
    uart_put_field_hex("reg0", last_result->reg0);
    uart_put_field_hex("l14", last_result->first_l14_word);
    uart_put_field_hex("l20", last_result->first_l20_word);
    uart_puts("\r\n");
}

static void uart_print_result(uint32_t seq, int rc, const yolo_hw_result_t *result)
{
    if (rc == 0) {
        uart_puts("DONE");
    } else {
        uart_puts("FAIL");
    }

    uart_put_field_hex("seq", seq);
    uart_put_field_hex("cycles", result->cycles);
    uart_put_field_hex("polls", result->polls);
    uart_put_field_hex("reg0", result->reg0);
    uart_put_field_hex("l14", result->first_l14_word);
    uart_put_field_hex("l20", result->first_l20_word);
    uart_puts("\r\n");
}

static void uart_print_help(void)
{
    uart_puts("CMDS: PING, STATUS, RUN [seq] [RELOAD], HELP\r\n");
    uart_puts("NOTE: input/weights use existing JTAG DDR staging windows.\r\n");
}

static void process_uart_line(char *line,
                              yolo_hw_t *hw,
                              uint32_t *run_count,
                              uint32_t *last_uart_seq,
                              uint32_t *last_rc,
                              yolo_hw_result_t *last_result)
{
    const char *cursor = line;

    if (token_match(&cursor, "PING")) {
        uart_puts("PONG\r\n");
    } else if (token_match(&cursor, "HELP")) {
        uart_print_help();
    } else if (token_match(&cursor, "STATUS")) {
        uart_print_status(hw, *run_count, *last_uart_seq, *last_rc, last_result);
    } else if (token_match(&cursor, "RUN")) {
        uint32_t seq = *last_uart_seq + 1u;
        uint32_t flags = 0u;

        if (parse_u32(&cursor, &seq) == 0) {
            cursor = skip_spaces(cursor);
        }

        if (token_match(&cursor, "RELOAD")) {
            flags |= YOLO_FLAG_RELOAD_WEIGHTS;
        }

        uart_puts("BUSY");
        uart_put_field_hex("seq", seq);
        uart_puts("\r\n");

        mailbox[MBX_STATUS] = YOLO_STATUS_BUSY;
        mailbox[MBX_REQUEST_SEQ] = seq;
        mailbox[MBX_ERROR] = 0u;
        publish_static_mailbox_fields(hw, *run_count);

        *last_rc = (uint32_t)run_forward_command(hw, flags, last_result, run_count);
        *last_uart_seq = seq;
        publish_static_mailbox_fields(hw, *run_count);
        publish_result_mailbox_fields(last_result);

        mailbox[MBX_DONE_SEQ] = seq;
        if (*last_rc == 0u) {
            mailbox[MBX_STATUS] = YOLO_STATUS_DONE;
        } else {
            mailbox[MBX_ERROR] = 1u;
            mailbox[MBX_STATUS] = YOLO_STATUS_FAIL;
        }

        uart_print_result(seq, (int)*last_rc, last_result);
    } else if (*skip_spaces(line) != '\0') {
        uart_puts("ERR unknown command\r\n");
        uart_print_help();
    }
}

int main(void)
{
    yolo_hw_t hw;
    uint32_t last_seq = mailbox[MBX_DONE_SEQ];
    uint32_t last_uart_seq = 0u;
    uint32_t last_rc = 0xFFFFFFFFu;
    uint32_t run_count = 0u;
    yolo_hw_result_t last_result;
    char uart_line[64];
    uint32_t uart_line_len = 0u;

    yolo_hw_init(&hw);
    last_result.reg0 = 0u;
    last_result.cycles = 0u;
    last_result.polls = 0u;
    last_result.first_l14_word = 0u;
    last_result.first_l20_word = 0u;

    uart_init();
    uart_puts("YOLOMB READY clk_hz=");
    uart_put_hex32(YOLO_CORE_CLOCK_HZ);
    uart_puts(" baud=");
    uart_put_hex32(YOLO_UART_BAUD);
    uart_puts("\r\n");
    uart_print_help();

    publish_static_mailbox_fields(&hw, run_count);

    if (mailbox[MBX_STATUS] != YOLO_CMD_RUN) {
        mailbox[MBX_STATUS] = YOLO_STATUS_READY;
    }

    while (1) {
        uint32_t cmd = mailbox[MBX_STATUS];
        uint32_t seq = mailbox[MBX_REQUEST_SEQ];

        if (cmd == YOLO_CMD_RUN && seq != last_seq) {
            int rc;

            mailbox[MBX_STATUS] = YOLO_STATUS_BUSY;
            mailbox[MBX_ERROR] = 0u;
            publish_static_mailbox_fields(&hw, run_count);

            rc = run_forward_command(&hw, mailbox[MBX_FLAGS], &last_result, &run_count);
            last_rc = (uint32_t)rc;

            publish_result_mailbox_fields(&last_result);
            mailbox[MBX_DONE_SEQ] = seq;
            last_seq = seq;
            publish_static_mailbox_fields(&hw, run_count);

            if (rc == 0) {
                mailbox[MBX_STATUS] = YOLO_STATUS_DONE;
            } else {
                mailbox[MBX_ERROR] = 1u;
                mailbox[MBX_STATUS] = YOLO_STATUS_FAIL;
            }
        }

        if (uart_line_poll(uart_line, &uart_line_len, (uint32_t)sizeof(uart_line)) != 0) {
            process_uart_line(uart_line, &hw, &run_count, &last_uart_seq, &last_rc, &last_result);
        }

        yolo_delay_cycles(1024u);
    }
}
