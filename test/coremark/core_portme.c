#include "coremark.h"

#include <stdarg.h>

#define DEBUG_REG ((volatile unsigned long *)0x40000000)
#define DEBUG_CHARACTER_TAG (0x01010UL << 44)

#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
#elif PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0;
volatile ee_s32 seed2_volatile = 0;
volatile ee_s32 seed3_volatile = 0x66;
#else
volatile ee_s32 seed1_volatile = 0x8;
volatile ee_s32 seed2_volatile = 0x8;
volatile ee_s32 seed3_volatile = 0x8;
#endif

volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;
ee_u32 default_num_contexts = 1;

static CORE_TICKS start_cycles;
static CORE_TICKS stop_cycles;
static unsigned long start_instructions;
static unsigned long stop_instructions;

static unsigned long read_mcycle(void) {
    unsigned long value;
    __asm__ volatile("csrr %0, mcycle" : "=r"(value));
    return value;
}

static unsigned long read_minstret(void) {
    unsigned long value;
    __asm__ volatile("csrr %0, minstret" : "=r"(value));
    return value;
}

void start_time(void) {
    start_cycles = read_mcycle();
    start_instructions = read_minstret();
}

void stop_time(void) {
    stop_instructions = read_minstret();
    stop_cycles = read_mcycle();
}

CORE_TICKS get_time(void) { return stop_cycles - start_cycles; }

secs_ret time_in_secs(CORE_TICKS ticks) {
    return (secs_ret)(ticks / COREMARK_CLOCK_HZ);
}

void portable_init(core_portable *p, int *argc, char *argv[]) {
    (void)argc;
    (void)argv;
    p->portable_id = 1;
    if (sizeof(ee_ptr_int) != sizeof(void *))
        ee_printf("ERROR! ee_ptr_int cannot hold a pointer\n");
    if (sizeof(ee_u32) != 4)
        ee_printf("ERROR! ee_u32 is not 32 bits\n");
}

void portable_fini(core_portable *p) {
    p->portable_id = 0;
    ee_printf("Retired instructions: %lu\n", stop_instructions - start_instructions);
    *DEBUG_REG = 1;
}

void *portable_malloc(ee_size_t size) {
    (void)size;
    return (void *)0;
}

void portable_free(void *p) { (void)p; }

static void write_char(char c) { *DEBUG_REG = DEBUG_CHARACTER_TAG | (ee_u8)c; }

static int write_string(const char *text) {
    int count = 0;
    while (*text) {
        write_char(*text++);
        count++;
    }
    return count;
}

static int write_unsigned(unsigned long value, unsigned base, int width, char pad) {
    static const char digits[] = "0123456789abcdef";
    char buffer[sizeof(value) * 8];
    int length = 0;
    int count = 0;

    do {
        buffer[length++] = digits[value % base];
        value /= base;
    } while (value != 0);
    while (length < width) {
        write_char(pad);
        width--;
        count++;
    }
    while (length != 0) {
        write_char(buffer[--length]);
        count++;
    }
    return count;
}

int ee_printf(const char *fmt, ...) {
    va_list args;
    int count = 0;
    va_start(args, fmt);

    while (*fmt) {
        if (*fmt != '%') {
            write_char(*fmt++);
            count++;
            continue;
        }
        fmt++;
        char pad = ' ';
        int width = 0;
        if (*fmt == '0') {
            pad = '0';
            fmt++;
        }
        while (*fmt >= '0' && *fmt <= '9')
            width = width * 10 + (*fmt++ - '0');
        int is_long = 0;
        if (*fmt == 'l') {
            is_long = 1;
            fmt++;
        }

        switch (*fmt++) {
            case '%':
                write_char('%');
                count++;
                break;
            case 'c':
                write_char((char)va_arg(args, int));
                count++;
                break;
            case 's':
                count += write_string(va_arg(args, const char *));
                break;
            case 'd':
            case 'i': {
                long value = is_long ? va_arg(args, long) : va_arg(args, int);
                unsigned long magnitude = (unsigned long)value;
                if (value < 0) {
                    write_char('-');
                    count++;
                    magnitude = 0 - magnitude;
                    if (width > 0) width--;
                }
                count += write_unsigned(magnitude, 10, width, pad);
                break;
            }
            case 'u':
                count += write_unsigned(
                    is_long ? va_arg(args, unsigned long) : va_arg(args, unsigned int),
                    10,
                    width,
                    pad);
                break;
            case 'x':
                count += write_unsigned(
                    is_long ? va_arg(args, unsigned long) : va_arg(args, unsigned int),
                    16,
                    width,
                    pad);
                break;
            default:
                write_char('?');
                count++;
                break;
        }
    }
    va_end(args);
    return count;
}
