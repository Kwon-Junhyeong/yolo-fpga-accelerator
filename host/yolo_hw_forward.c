#include "yolo_hw_forward.h"

#include <ctype.h>
#include <errno.h>
#include <stdlib.h>

#define YOLO_HW_L14_CONV_INDEX 14
#define YOLO_HW_L14_YOLO_INDEX 15
#define YOLO_HW_L20_CONV_INDEX 20
#define YOLO_HW_L20_YOLO_INDEX 21

#define YOLO_HW_L14_H 8
#define YOLO_HW_L14_W 8
#define YOLO_HW_L20_H 16
#define YOLO_HW_L20_W 16
#define YOLO_HW_HEAD_CHANNELS 195
#define YOLO_HW_HEAD_PAD_CHANNELS 196

#define YOLO_HW_L14_NEXT_INPUT_MULT 64
#define YOLO_HW_L20_NEXT_INPUT_MULT 1
#define YOLO_HW_HEAD_Q4_SCALE 16.0f
#define YOLO_HW_HEAD32_PARTITION_CHANNELS 32
#define YOLO_HW_L14_HEAD32_DENOM 8192.0f
#define YOLO_HW_L20_HEAD32_DENOM 4096.0f

#define YOLO_HW_PATH_MAX 4096
#define YOLO_HW_CMD_MAX 16384
#define YOLO_HW_JTAG_DEFAULT_SCRIPT "yolo_jtag_forward.ps1"
#define YOLO_HW_JTAG_DEFAULT_OUT_DIR "yolo_hw_jtag_runtime"

static unsigned long yolo_hw_stats_calls = 0;
static unsigned long yolo_hw_stats_cycle_calls = 0;
static unsigned long long yolo_hw_stats_total_cycles = 0;
static unsigned long long yolo_hw_stats_last_cycles = 0;
static double yolo_hw_stats_last_fps100 = 0.0;
static yolo_hw_backend yolo_hw_stats_last_backend = YOLO_HW_BACKEND_NONE;

static int yolo_hw_truthy(const char *value)
{
    if (!value) return 0;
    return strcmp(value, "1") == 0 ||
           strcmp(value, "true") == 0 ||
           strcmp(value, "TRUE") == 0 ||
           strcmp(value, "on") == 0 ||
           strcmp(value, "ON") == 0 ||
           strcmp(value, "yes") == 0 ||
           strcmp(value, "YES") == 0;
}

static int yolo_hw_falsey(const char *value)
{
    if (!value) return 0;
    return strcmp(value, "0") == 0 ||
           strcmp(value, "false") == 0 ||
           strcmp(value, "FALSE") == 0 ||
           strcmp(value, "off") == 0 ||
           strcmp(value, "OFF") == 0 ||
           strcmp(value, "none") == 0 ||
           strcmp(value, "NONE") == 0 ||
           strcmp(value, "cpu") == 0 ||
           strcmp(value, "CPU") == 0;
}

int yolo_hw_forward_enabled(void)
{
    const char *backend = getenv("YOLO_HW_BACKEND");
    const char *enable = getenv("YOLO_HW_ENABLE");

    if (backend) return !yolo_hw_falsey(backend);
    if (enable) return yolo_hw_truthy(enable);

    return yolo_hw_truthy(getenv("YOLO_FPGA_HEAD16"));
}

yolo_hw_backend yolo_hw_forward_backend(void)
{
    const char *backend = getenv("YOLO_HW_BACKEND");

    if (backend) {
        if (strcmp(backend, "snapshot") == 0 || strcmp(backend, "SNAPSHOT") == 0) {
            return YOLO_HW_BACKEND_SNAPSHOT;
        }
        if (strcmp(backend, "jtag") == 0 || strcmp(backend, "JTAG") == 0 ||
            strcmp(backend, "vivado-jtag") == 0 || strcmp(backend, "VIVADO-JTAG") == 0) {
            return YOLO_HW_BACKEND_JTAG;
        }
        if (strcmp(backend, "uart") == 0 || strcmp(backend, "UART") == 0) {
            return YOLO_HW_BACKEND_UART;
        }
        if (yolo_hw_falsey(backend)) return YOLO_HW_BACKEND_NONE;

        fprintf(stderr, "[yolo-hw] unknown YOLO_HW_BACKEND=%s\n", backend);
        return YOLO_HW_BACKEND_NONE;
    }

    if (yolo_hw_truthy(getenv("YOLO_HW_ENABLE")) ||
        yolo_hw_truthy(getenv("YOLO_FPGA_HEAD16"))) {
        return YOLO_HW_BACKEND_SNAPSHOT;
    }

    return YOLO_HW_BACKEND_NONE;
}

const char *yolo_hw_forward_backend_name(yolo_hw_backend backend)
{
    switch (backend) {
    case YOLO_HW_BACKEND_SNAPSHOT: return "snapshot";
    case YOLO_HW_BACKEND_JTAG: return "jtag";
    case YOLO_HW_BACKEND_UART: return "uart";
    case YOLO_HW_BACKEND_NONE:
    default:
        return "none";
    }
}

void yolo_hw_forward_reset_stats(void)
{
    yolo_hw_stats_calls = 0;
    yolo_hw_stats_cycle_calls = 0;
    yolo_hw_stats_total_cycles = 0;
    yolo_hw_stats_last_cycles = 0;
    yolo_hw_stats_last_fps100 = 0.0;
    yolo_hw_stats_last_backend = YOLO_HW_BACKEND_NONE;
}

static void yolo_hw_forward_note_stats(yolo_hw_backend backend,
                                       const char *cycles_text,
                                       const char *fps100_text)
{
    yolo_hw_stats_calls++;
    yolo_hw_stats_last_backend = backend;

    if (cycles_text && cycles_text[0]) {
        char *endptr = NULL;
        unsigned long long cycles;
#if defined(_MSC_VER)
        cycles = _strtoui64(cycles_text, &endptr, 0);
#else
        cycles = strtoull(cycles_text, &endptr, 0);
#endif
        if (endptr && endptr != cycles_text) {
            yolo_hw_stats_cycle_calls++;
            yolo_hw_stats_total_cycles += cycles;
            yolo_hw_stats_last_cycles = cycles;
        }
    }

    if (fps100_text && fps100_text[0]) {
        yolo_hw_stats_last_fps100 = atof(fps100_text);
    }
}

void yolo_hw_forward_print_stats(void)
{
    if (yolo_hw_stats_calls == 0) return;

    fprintf(stderr,
            "\n[yolo-hw] summary: backend=%s forward_calls=%lu\n",
            yolo_hw_forward_backend_name(yolo_hw_stats_last_backend),
            yolo_hw_stats_calls);

    if (yolo_hw_stats_cycle_calls > 0) {
        const double avg_cycles =
            (double)yolo_hw_stats_total_cycles / (double)yolo_hw_stats_cycle_calls;
        const double fps100 = avg_cycles > 0.0 ? 100000000.0 / avg_cycles : 0.0;

        fprintf(stderr,
                "[yolo-hw] measured accelerator cycles: avg=%.3f images=%lu fps@100MHz=%.3f last=%llu",
                avg_cycles,
                yolo_hw_stats_cycle_calls,
                fps100,
                yolo_hw_stats_last_cycles);
        if (yolo_hw_stats_last_fps100 > 0.0) {
            fprintf(stderr, " last_fps@100MHz=%.3f", yolo_hw_stats_last_fps100);
        }
        fprintf(stderr, "\n");
    }
    else {
        fprintf(stderr,
                "[yolo-hw] no live cycle counter was returned. This run used pre-existing FPGA head dumps or a dry-run protocol.\n");
    }
}

static const char *yolo_hw_env_first(const char *primary, const char *legacy)
{
    const char *value = getenv(primary);
    if (value && value[0]) return value;
    value = getenv(legacy);
    if (value && value[0]) return value;
    return NULL;
}

static int yolo_hw_path_join(char *out, size_t out_size, const char *dir, const char *file)
{
    size_t len;
    if (!out || !dir || !file || out_size == 0) return -1;
    len = strlen(dir);
    if (len > 0 && (dir[len - 1] == '/' || dir[len - 1] == '\\')) {
        return snprintf(out, out_size, "%s%s", dir, file) >= (int)out_size ? -1 : 0;
    }
    return snprintf(out, out_size, "%s/%s", dir, file) >= (int)out_size ? -1 : 0;
}

static const char *yolo_hw_basename(const char *path)
{
    const char *slash;
    const char *backslash;
    if (!path) return "";
    slash = strrchr(path, '/');
    backslash = strrchr(path, '\\');
    if (slash && backslash) return (slash > backslash) ? slash + 1 : backslash + 1;
    if (slash) return slash + 1;
    if (backslash) return backslash + 1;
    return path;
}

static void yolo_hw_stem_from_path(const char *path, char *stem, size_t stem_size)
{
    const char *base = yolo_hw_basename(path);
    const char *dot = strrchr(base, '.');
    size_t n = dot ? (size_t)(dot - base) : strlen(base);
    if (stem_size == 0) return;
    if (n >= stem_size) n = stem_size - 1;
    memcpy(stem, base, n);
    stem[n] = '\0';
}

static int yolo_hw_append_text(char *out, size_t out_size, const char *text)
{
    size_t used;
    size_t add;
    if (!out || !text || out_size == 0) return -1;
    used = strlen(out);
    add = strlen(text);
    if (used + add + 1 > out_size) return -1;
    memcpy(out + used, text, add + 1);
    return 0;
}

static int yolo_hw_append_quoted(char *out, size_t out_size, const char *value)
{
    const char *p;
    if (yolo_hw_append_text(out, out_size, "\"") != 0) return -1;
    if (value) {
        for (p = value; *p; ++p) {
            char tmp[3];
            if (*p == '"') {
                if (yolo_hw_append_text(out, out_size, "\\\"") != 0) return -1;
            }
            else {
                tmp[0] = *p;
                tmp[1] = '\0';
                if (yolo_hw_append_text(out, out_size, tmp) != 0) return -1;
            }
        }
    }
    return yolo_hw_append_text(out, out_size, "\"");
}

static int yolo_hw_append_switch(char *out, size_t out_size,
                                 const char *name, const char *value)
{
    if (!value || !value[0]) return 0;
    if (yolo_hw_append_text(out, out_size, " ") != 0) return -1;
    if (yolo_hw_append_text(out, out_size, name) != 0) return -1;
    if (yolo_hw_append_text(out, out_size, " ") != 0) return -1;
    return yolo_hw_append_quoted(out, out_size, value);
}

static int yolo_hw_append_flag(char *out, size_t out_size, const char *name, int enable)
{
    if (!enable) return 0;
    if (yolo_hw_append_text(out, out_size, " ") != 0) return -1;
    return yolo_hw_append_text(out, out_size, name);
}

static int yolo_hw_read_jtag_paths(const char *paths_file,
                                   char *l14_path,
                                   size_t l14_size,
                                   char *l20_path,
                                   size_t l20_size,
                                   char *cycles,
                                   size_t cycles_size,
                                   char *fps100,
                                   size_t fps100_size)
{
    FILE *fp;
    char line[YOLO_HW_PATH_MAX * 2];
    if (!paths_file || !l14_path || !l20_path) return -1;

    l14_path[0] = '\0';
    l20_path[0] = '\0';
    if (cycles && cycles_size) cycles[0] = '\0';
    if (fps100 && fps100_size) fps100[0] = '\0';

    fp = fopen(paths_file, "r");
    if (!fp) {
        fprintf(stderr, "[yolo-hw] failed to open JTAG paths file: %s\n", paths_file);
        return -1;
    }

    while (fgets(line, sizeof(line), fp)) {
        char *eq = strchr(line, '=');
        char *key;
        char *value;
        if (!eq) continue;
        *eq = '\0';
        key = line;
        value = eq + 1;
        value[strcspn(value, "\r\n")] = '\0';

        if (strcmp(key, "YOLO_HW_L14") == 0) {
            snprintf(l14_path, l14_size, "%s", value);
        }
        else if (strcmp(key, "YOLO_HW_L20") == 0) {
            snprintf(l20_path, l20_size, "%s", value);
        }
        else if (strcmp(key, "YOLO_HW_CYCLES") == 0 && cycles && cycles_size) {
            snprintf(cycles, cycles_size, "%s", value);
        }
        else if (strcmp(key, "YOLO_HW_FPS_100MHZ") == 0 && fps100 && fps100_size) {
            snprintf(fps100, fps100_size, "%s", value);
        }
    }

    fclose(fp);
    return (l14_path[0] && l20_path[0]) ? 0 : -1;
}

static void yolo_hw_normalize_path(const char *in, char *out, size_t out_size)
{
    size_t i;
    if (out_size == 0) return;
    if (!in) {
        out[0] = '\0';
        return;
    }
    for (i = 0; i + 1 < out_size && in[i]; ++i) {
        char c = in[i];
        if (c == '\\') c = '/';
        out[i] = (char)tolower((unsigned char)c);
    }
    out[i] = '\0';
}

static int yolo_hw_same_path(const char *a, const char *b)
{
    char na[YOLO_HW_PATH_MAX];
    char nb[YOLO_HW_PATH_MAX];
    yolo_hw_normalize_path(a, na, sizeof(na));
    yolo_hw_normalize_path(b, nb, sizeof(nb));
    return strcmp(na, nb) == 0;
}

static int yolo_hw_manifest_lookup_stem(const char *manifest_path,
                                        const char *image_path,
                                        int image_index,
                                        char *stem,
                                        size_t stem_size)
{
    FILE *fp;
    char line[YOLO_HW_PATH_MAX * 2];
    if (!manifest_path || !stem || stem_size == 0) return -1;

    fp = fopen(manifest_path, "r");
    if (!fp) {
        fprintf(stderr, "[yolo-hw] failed to open manifest: %s\n", manifest_path);
        return -1;
    }

    while (fgets(line, sizeof(line), fp)) {
        char *cols[4] = {0};
        char *cursor = line;
        int col;
        int row_index;
        for (col = 0; col < 4; ++col) {
            cols[col] = cursor;
            cursor = strchr(cursor, '\t');
            if (!cursor) break;
            *cursor = '\0';
            ++cursor;
        }
        if (col < 3 || !cols[0] || !cols[1] || !cols[3]) continue;
        cols[3][strcspn(cols[3], "\r\n")] = '\0';
        if (strcmp(cols[0], "index") == 0) continue;

        row_index = atoi(cols[0]);
        if ((image_index >= 0 && row_index == image_index) ||
            (image_path && yolo_hw_same_path(cols[1], image_path))) {
            snprintf(stem, stem_size, "%s", cols[3]);
            fclose(fp);
            return 0;
        }
    }

    fclose(fp);
    return -1;
}

static int yolo_hw_resolve_snapshot_paths(const char *image_path,
                                          int image_index,
                                          char *l14_path,
                                          size_t l14_size,
                                          char *l20_path,
                                          size_t l20_size)
{
    const char *l14_env = yolo_hw_env_first("YOLO_HW_L14", "YOLO_FPGA_L14");
    const char *l20_env = yolo_hw_env_first("YOLO_HW_L20", "YOLO_FPGA_L20");
    const char *dir = yolo_hw_env_first("YOLO_HW_SNAPSHOT_DIR", "YOLO_FPGA_SNAPSHOT_DIR");
    const char *manifest = yolo_hw_env_first("YOLO_HW_MANIFEST", "YOLO_FPGA_MANIFEST");
    const char *stem_env = yolo_hw_env_first("YOLO_HW_STEM", "YOLO_FPGA_STEM");
    char stem[YOLO_HW_PATH_MAX];
    char file_name[YOLO_HW_PATH_MAX];

    if (l14_env && l20_env) {
        snprintf(l14_path, l14_size, "%s", l14_env);
        snprintf(l20_path, l20_size, "%s", l20_env);
        return 0;
    }

    if (!dir) {
        fprintf(stderr, "[yolo-hw] snapshot backend needs YOLO_HW_L14/YOLO_HW_L20 or YOLO_HW_SNAPSHOT_DIR\n");
        return -1;
    }

    if (stem_env && stem_env[0]) {
        snprintf(stem, sizeof(stem), "%s", stem_env);
    }
    else if (manifest && yolo_hw_manifest_lookup_stem(manifest, image_path, image_index, stem, sizeof(stem)) == 0) {

    }
    else if (image_path) {
        yolo_hw_stem_from_path(image_path, stem, sizeof(stem));
    }
    else if (image_index >= 0) {
        snprintf(stem, sizeof(stem), "%04d", image_index);
    }
    else {
        fprintf(stderr, "[yolo-hw] no image path/index available for snapshot lookup\n");
        return -1;
    }

    snprintf(file_name, sizeof(file_name), "%s_L14.txt", stem);
    if (yolo_hw_path_join(l14_path, l14_size, dir, file_name) != 0) return -1;
    snprintf(file_name, sizeof(file_name), "%s_L20.txt", stem);
    if (yolo_hw_path_join(l20_path, l20_size, dir, file_name) != 0) return -1;
    return 0;
}

static int yolo_hw_parse_snapshot_word(const char *line, uint32_t *word)
{
    const char *p;
    char *endptr;
    unsigned long value;
    if (!line || !word) return 0;

    p = strstr(line, "val=0x");
    if (p) p += 6;
    else {
        p = line;
        while (*p && isspace((unsigned char)*p)) ++p;
        if (*p == '\0' || *p == '#') return 0;
    }

    errno = 0;
    value = strtoul(p, &endptr, 16);
    if (p == endptr || errno != 0) return -1;
    *word = (uint32_t)value;
    return 1;
}

static int yolo_hw_load_head16_tensor(const char *path,
                                      float *dst,
                                      int channels,
                                      int pad_channels,
                                      int height,
                                      int width,
                                      int next_input_mult)
{
    FILE *fp;
    char line[1024];
    int groups = (pad_channels + 1) / 2;
    int expected_words = height * width * groups;
    int plane = height * width;
    int word_count = 0;
    float denom = (float)next_input_mult * YOLO_HW_HEAD_Q4_SCALE;

    fp = fopen(path, "r");
    if (!fp) {
        fprintf(stderr, "[yolo-hw] failed to open snapshot: %s\n", path);
        return -1;
    }

    while (fgets(line, sizeof(line), fp)) {
        uint32_t word = 0;
        int parsed = yolo_hw_parse_snapshot_word(line, &word);
        int pix, group, lane;
        if (parsed == 0) continue;
        if (parsed < 0) {
            fprintf(stderr, "[yolo-hw] failed to parse snapshot line in %s\n", path);
            fclose(fp);
            return -1;
        }
        if (word_count >= expected_words) {
            fprintf(stderr, "[yolo-hw] too many words in %s, expected %d\n", path, expected_words);
            fclose(fp);
            return -1;
        }

        pix = word_count / groups;
        group = word_count % groups;
        for (lane = 0; lane < 2; ++lane) {
            int ch = group * 2 + lane;
            if (ch < channels) {
                int16_t raw = (int16_t)((word >> (16 * lane)) & 0xFFFF);
                dst[ch * plane + pix] = (float)raw / denom;
            }
        }
        ++word_count;
    }

    fclose(fp);
    if (word_count != expected_words) {
        fprintf(stderr, "[yolo-hw] %s: expected %d words, got %d\n",
                path, expected_words, word_count);
        return -1;
    }
    return 0;
}

static int yolo_hw_load_head32_partition_tensor(const char *path,
                                                float *dst,
                                                int channels,
                                                int height,
                                                int width,
                                                float denom)
{
    FILE *fp;
    char line[1024];
    int plane = height * width;
    int expected_words = plane * channels;
    int word_count = 0;
    int part_base = 0;

    fp = fopen(path, "r");
    if (!fp) {
        fprintf(stderr, "[yolo-hw] failed to open snapshot: %s\n", path);
        return -1;
    }

    while (part_base < channels) {
        int part_channels = channels - part_base;
        int pix, local_ch;
        if (part_channels > YOLO_HW_HEAD32_PARTITION_CHANNELS) {
            part_channels = YOLO_HW_HEAD32_PARTITION_CHANNELS;
        }

        for (pix = 0; pix < plane; ++pix) {
            for (local_ch = 0; local_ch < part_channels; ++local_ch) {
                uint32_t word = 0;
                int parsed;

                do {
                    if (!fgets(line, sizeof(line), fp)) {
                        fprintf(stderr, "[yolo-hw] %s: expected %d words, got %d\n",
                                path, expected_words, word_count);
                        fclose(fp);
                        return -1;
                    }
                    parsed = yolo_hw_parse_snapshot_word(line, &word);
                    if (parsed < 0) {
                        fprintf(stderr, "[yolo-hw] failed to parse snapshot line in %s\n", path);
                        fclose(fp);
                        return -1;
                    }
                } while (parsed == 0);

                dst[(part_base + local_ch) * plane + pix] = (float)((int32_t)word) / denom;
                ++word_count;
            }
        }

        part_base += part_channels;
    }

    while (fgets(line, sizeof(line), fp)) {
        uint32_t word = 0;
        int parsed = yolo_hw_parse_snapshot_word(line, &word);
        if (parsed > 0) {
            fprintf(stderr, "[yolo-hw] too many words in %s, expected %d\n", path, expected_words);
            fclose(fp);
            return -1;
        }
        if (parsed < 0) {
            fprintf(stderr, "[yolo-hw] failed to parse snapshot line in %s\n", path);
            fclose(fp);
            return -1;
        }
    }

    fclose(fp);
    return 0;
}

static int yolo_hw_check_head_layer(network net, int conv_index, int yolo_index,
                                    int height, int width, const char *name)
{
    int expected_outputs = YOLO_HW_HEAD_CHANNELS * height * width;
    if (net.n <= yolo_index) {
        fprintf(stderr, "[yolo-hw] network has %d layers; need layer %d for %s\n",
                net.n, yolo_index, name);
        return -1;
    }
    if (net.layers[conv_index].outputs != expected_outputs) {
        fprintf(stderr, "[yolo-hw] %s conv outputs mismatch: expected %d, got %d\n",
                name, expected_outputs, net.layers[conv_index].outputs);
        return -1;
    }
    if (net.layers[yolo_index].outputs != expected_outputs ||
        net.layers[yolo_index].type != YOLO) {
        fprintf(stderr, "[yolo-hw] %s YOLO layer mismatch at index %d\n",
                name, yolo_index);
        return -1;
    }
    return 0;
}

static void yolo_hw_run_yolo_layer(network net, int conv_index, int yolo_index)
{
    network_state state;
    memset(&state, 0, sizeof(state));
    state.net = net;
    state.index = yolo_index;
    state.input = net.layers[conv_index].output;
    state.train = 0;
    forward_yolo_layer_cpu(net.layers[yolo_index], state);
}

int yolo_hw_forward_from_head16_files(network net, const char *l14_path, const char *l20_path)
{
    if (yolo_hw_check_head_layer(net, YOLO_HW_L14_CONV_INDEX, YOLO_HW_L14_YOLO_INDEX,
                                 YOLO_HW_L14_H, YOLO_HW_L14_W, "L14") != 0) {
        return -1;
    }
    if (yolo_hw_check_head_layer(net, YOLO_HW_L20_CONV_INDEX, YOLO_HW_L20_YOLO_INDEX,
                                 YOLO_HW_L20_H, YOLO_HW_L20_W, "L20") != 0) {
        return -1;
    }

    if (yolo_hw_load_head16_tensor(l14_path, net.layers[YOLO_HW_L14_CONV_INDEX].output,
                                   YOLO_HW_HEAD_CHANNELS, YOLO_HW_HEAD_PAD_CHANNELS,
                                   YOLO_HW_L14_H, YOLO_HW_L14_W, YOLO_HW_L14_NEXT_INPUT_MULT) != 0) {
        return -1;
    }
    if (yolo_hw_load_head16_tensor(l20_path, net.layers[YOLO_HW_L20_CONV_INDEX].output,
                                   YOLO_HW_HEAD_CHANNELS, YOLO_HW_HEAD_PAD_CHANNELS,
                                   YOLO_HW_L20_H, YOLO_HW_L20_W, YOLO_HW_L20_NEXT_INPUT_MULT) != 0) {
        return -1;
    }

    yolo_hw_run_yolo_layer(net, YOLO_HW_L14_CONV_INDEX, YOLO_HW_L14_YOLO_INDEX);
    yolo_hw_run_yolo_layer(net, YOLO_HW_L20_CONV_INDEX, YOLO_HW_L20_YOLO_INDEX);
    return 0;
}

int yolo_hw_forward_from_head32_partition_files(network net, const char *l14_path, const char *l20_path)
{
    if (yolo_hw_check_head_layer(net, YOLO_HW_L14_CONV_INDEX, YOLO_HW_L14_YOLO_INDEX,
                                 YOLO_HW_L14_H, YOLO_HW_L14_W, "L14") != 0) {
        return -1;
    }
    if (yolo_hw_check_head_layer(net, YOLO_HW_L20_CONV_INDEX, YOLO_HW_L20_YOLO_INDEX,
                                 YOLO_HW_L20_H, YOLO_HW_L20_W, "L20") != 0) {
        return -1;
    }

    if (yolo_hw_load_head32_partition_tensor(l14_path, net.layers[YOLO_HW_L14_CONV_INDEX].output,
                                             YOLO_HW_HEAD_CHANNELS,
                                             YOLO_HW_L14_H, YOLO_HW_L14_W,
                                             YOLO_HW_L14_HEAD32_DENOM) != 0) {
        return -1;
    }
    if (yolo_hw_load_head32_partition_tensor(l20_path, net.layers[YOLO_HW_L20_CONV_INDEX].output,
                                             YOLO_HW_HEAD_CHANNELS,
                                             YOLO_HW_L20_H, YOLO_HW_L20_W,
                                             YOLO_HW_L20_HEAD32_DENOM) != 0) {
        return -1;
    }

    yolo_hw_run_yolo_layer(net, YOLO_HW_L14_CONV_INDEX, YOLO_HW_L14_YOLO_INDEX);
    yolo_hw_run_yolo_layer(net, YOLO_HW_L20_CONV_INDEX, YOLO_HW_L20_YOLO_INDEX);
    return 0;
}

static int yolo_hw_snapshot_mode_is_head32(void)
{
    const char *mode = getenv("YOLO_HW_SNAPSHOT_MODE");
    if (!mode || !mode[0]) mode = getenv("YOLO_HW_HEAD_MODE");
    if (!mode || !mode[0]) return 0;

    return strcmp(mode, "head32") == 0 ||
           strcmp(mode, "HEAD32") == 0 ||
           strcmp(mode, "int32") == 0 ||
           strcmp(mode, "INT32") == 0 ||
           strcmp(mode, "int32-partition") == 0 ||
           strcmp(mode, "INT32-PARTITION") == 0 ||
           strcmp(mode, "head32-partition") == 0 ||
           strcmp(mode, "HEAD32-PARTITION") == 0;
}

static int yolo_hw_forward_snapshot(network net, const char *image_path, int image_index)
{
    char l14_path[YOLO_HW_PATH_MAX];
    char l20_path[YOLO_HW_PATH_MAX];
    int head32 = yolo_hw_snapshot_mode_is_head32();

    if (yolo_hw_resolve_snapshot_paths(image_path, image_index,
                                       l14_path, sizeof(l14_path),
                                       l20_path, sizeof(l20_path)) != 0) {
        return -1;
    }
    if (head32) {
        if (yolo_hw_forward_from_head32_partition_files(net, l14_path, l20_path) != 0) {
            return -1;
        }
    }
    else if (yolo_hw_forward_from_head16_files(net, l14_path, l20_path) != 0) {
        return -1;
    }

    fprintf(stderr, "[yolo-hw] backend=snapshot mode=%s L14=%s L20=%s\n",
            head32 ? "head32-partition" : "head16-q4", l14_path, l20_path);
    yolo_hw_forward_note_stats(YOLO_HW_BACKEND_SNAPSHOT, NULL, NULL);
    return 1;
}

static int yolo_hw_forward_jtag(network net,
                                float *input,
                                const char *image_path,
                                int image_index)
{
    const char *script = getenv("YOLO_HW_JTAG_SCRIPT");
    const char *out_dir = getenv("YOLO_HW_JTAG_OUT_DIR");
    const char *paths_file_env = getenv("YOLO_HW_JTAG_PATHS");
    const char *input_hex = getenv("YOLO_HW_JTAG_INPUT_HEX");
    const char *manifest = getenv("YOLO_HW_JTAG_MANIFEST");
    const char *target_serial = getenv("YOLO_HW_JTAG_TARGET_SERIAL");
    const char *xsct = getenv("YOLO_HW_XSCT");
    const char *bitstream = getenv("YOLO_HW_JTAG_BITSTREAM");
    const char *elf = getenv("YOLO_HW_JTAG_ELF");
    const char *seq_env = getenv("YOLO_HW_JTAG_SEQ");
    const char *skip_env = getenv("YOLO_HW_JTAG_SKIP_WEIGHT_STAGE");
    const char *reload_env = getenv("YOLO_HW_JTAG_RELOAD_WEIGHTS");
    const char *program_env = getenv("YOLO_HW_JTAG_PROGRAM");
    const char *dry_run_env = getenv("YOLO_HW_JTAG_DRY_RUN");
    char cmd[YOLO_HW_CMD_MAX];
    char image_index_arg[32];
    char seq_arg[32];
    char paths_file[YOLO_HW_PATH_MAX];
    char l14_path[YOLO_HW_PATH_MAX];
    char l20_path[YOLO_HW_PATH_MAX];
    char cycles[64];
    char fps100[64];
    int seq;
    int skip_weight_stage;
    int reload_weights;
    int program;
    int dry_run;
    int rc;

    (void)input;

    if (!script || !script[0]) script = YOLO_HW_JTAG_DEFAULT_SCRIPT;
    if (!out_dir || !out_dir[0]) out_dir = YOLO_HW_JTAG_DEFAULT_OUT_DIR;

    if (paths_file_env && paths_file_env[0]) {
        snprintf(paths_file, sizeof(paths_file), "%s", paths_file_env);
    }
    else if (yolo_hw_path_join(paths_file, sizeof(paths_file), out_dir, "last_paths.env") != 0) {
        fprintf(stderr, "[yolo-hw] failed to build JTAG paths file path\n");
        return -1;
    }

    seq = seq_env && seq_env[0] ? atoi(seq_env) : (image_index >= 0 ? image_index + 1 : 1);
    if (seq <= 0) seq = 1;
    skip_weight_stage = yolo_hw_truthy(skip_env);
    if (reload_env && reload_env[0]) {
        reload_weights = yolo_hw_truthy(reload_env);
    }
    else {

        reload_weights = !skip_weight_stage;
    }
    program = yolo_hw_truthy(program_env);
    dry_run = yolo_hw_truthy(dry_run_env);

    snprintf(image_index_arg, sizeof(image_index_arg), "%d", image_index);
    snprintf(seq_arg, sizeof(seq_arg), "%d", seq);

    cmd[0] = '\0';
    if (yolo_hw_append_text(cmd, sizeof(cmd), "powershell -NoProfile -ExecutionPolicy Bypass -File ") != 0 ||
        yolo_hw_append_quoted(cmd, sizeof(cmd), script) != 0 ||
        yolo_hw_append_switch(cmd, sizeof(cmd), "-ImagePath", image_path ? image_path : "") != 0 ||
        yolo_hw_append_switch(cmd, sizeof(cmd), "-ImageIndex", image_index_arg) != 0 ||
        yolo_hw_append_switch(cmd, sizeof(cmd), "-OutDir", out_dir) != 0 ||
        yolo_hw_append_switch(cmd, sizeof(cmd), "-PathsFile", paths_file) != 0 ||
        yolo_hw_append_switch(cmd, sizeof(cmd), "-Seq", seq_arg) != 0 ||
        yolo_hw_append_switch(cmd, sizeof(cmd), "-InputHex", input_hex) != 0 ||
        yolo_hw_append_switch(cmd, sizeof(cmd), "-Manifest", manifest) != 0 ||
        yolo_hw_append_switch(cmd, sizeof(cmd), "-TargetSerial", target_serial) != 0 ||
        yolo_hw_append_switch(cmd, sizeof(cmd), "-Xsct", xsct) != 0 ||
        yolo_hw_append_switch(cmd, sizeof(cmd), "-Bitstream", bitstream) != 0 ||
        yolo_hw_append_switch(cmd, sizeof(cmd), "-Elf", elf) != 0 ||
        yolo_hw_append_flag(cmd, sizeof(cmd), "-Program", program) != 0 ||
        yolo_hw_append_flag(cmd, sizeof(cmd), "-SkipWeightStage", skip_weight_stage) != 0 ||
        yolo_hw_append_flag(cmd, sizeof(cmd), "-ReloadWeights", reload_weights) != 0 ||
        yolo_hw_append_flag(cmd, sizeof(cmd), "-DryRun", dry_run) != 0) {
        fprintf(stderr, "[yolo-hw] JTAG command line is too long\n");
        return -1;
    }

    fprintf(stderr, "[yolo-hw] backend=jtag launching board protocol seq=%d image=%s\n",
            seq, image_path ? image_path : "(null)");
    rc = system(cmd);
    if (rc != 0) {
        fprintf(stderr, "[yolo-hw] JTAG protocol command failed rc=%d\n", rc);
        return -1;
    }

    if (yolo_hw_read_jtag_paths(paths_file,
                                l14_path, sizeof(l14_path),
                                l20_path, sizeof(l20_path),
                                cycles, sizeof(cycles),
                                fps100, sizeof(fps100)) != 0) {
        fprintf(stderr, "[yolo-hw] failed to read JTAG output paths from %s\n", paths_file);
        return -1;
    }

    if (yolo_hw_forward_from_head32_partition_files(net, l14_path, l20_path) != 0) {
        return -1;
    }

    fprintf(stderr, "[yolo-hw] backend=jtag loaded head32 L14=%s L20=%s", l14_path, l20_path);
    if (cycles[0]) fprintf(stderr, " cycles=%s", cycles);
    if (fps100[0]) fprintf(stderr, " fps_100mhz=%s", fps100);
    fprintf(stderr, "\n");
    yolo_hw_forward_note_stats(YOLO_HW_BACKEND_JTAG, cycles, fps100);
    return 1;
}

static int yolo_hw_forward_unimplemented(yolo_hw_backend backend)
{
    fprintf(stderr,
            "[yolo-hw] backend=%s is not implemented in the C runtime yet. "
            "Use YOLO_HW_BACKEND=jtag for live board forward, or "
            "YOLO_HW_BACKEND=snapshot with YOLO_HW_SNAPSHOT_MODE=head32-partition "
            "for verified FPGA raw int32 head dumps.\n",
            yolo_hw_forward_backend_name(backend));
    return -1;
}

int yolo_hw_forward_if_requested(network net,
                                 float *input,
                                 const char *image_path,
                                 int image_index)
{
    yolo_hw_backend backend;
    (void)input;

    if (!yolo_hw_forward_enabled()) return 0;

    backend = yolo_hw_forward_backend();
    switch (backend) {
    case YOLO_HW_BACKEND_SNAPSHOT:
        return yolo_hw_forward_snapshot(net, image_path, image_index);
    case YOLO_HW_BACKEND_JTAG:
        return yolo_hw_forward_jtag(net, input, image_path, image_index);
    case YOLO_HW_BACKEND_UART:
        return yolo_hw_forward_unimplemented(backend);
    case YOLO_HW_BACKEND_NONE:
    default:
        return 0;
    }
}
