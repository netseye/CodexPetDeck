/*
 * MK20 / Allwinner T113-S3 Codex Micro HID bridge.
 *
 * This is deliberately freestanding: the production image uses glibc 2.23,
 * while the available host compiler targets a newer runtime.  Using Linux
 * ARM EABI syscalls directly keeps the deployed binary independent of libc.
 *
 * USB exposes only the Codex Micro HID function.  A local pseudo-terminal is
 * linked to /dev/ttyGS0 so the unmodified KeyboardDevice process still sees
 * its normal V2 serial stream; HID channel 3 carries that stream to/from the
 * macOS companion without consuming another pair of USB endpoints.
 */

typedef unsigned char u8;
typedef unsigned int u32;
typedef unsigned long usize;

#define SYS_EXIT       1
#define SYS_FORK       2
#define SYS_READ       3
#define SYS_WRITE      4
#define SYS_OPEN       5
#define SYS_CLOSE      6
#define SYS_UNLINK    10
#define SYS_EXECVE    11
#define SYS_CHMOD     15
#define SYS_IOCTL     54
#define SYS_FCNTL     55
#define SYS_SYMLINK   83
#define SYS_NANOSLEEP 162
#define SYS_POLL      168

#define O_WRONLY    1
#define O_RDWR      2
#define O_CREAT   0100
#define O_TRUNC  01000
#define O_NOCTTY  0400
#define O_NONBLOCK 04000
#define F_SETFL      4

#define TCGETS     0x5401
#define TCSETS     0x5402
#define TIOCSPTLCK 0x40045431
#define TIOCGPTN   0x80045430

#define POLLIN   0x0001
#define POLLERR  0x0008
#define POLLHUP  0x0010
#define POLLNVAL 0x0020

#define REPORT_ID 6
#define REPORT_SIZE 64
#define RPC_CHANNEL 2
#define V2_CHANNEL 3
#define RPC_CHUNK 61

struct timespec32 {
    long seconds;
    long nanoseconds;
};

struct pollfd32 {
    int fd;
    short events;
    short revents;
};

typedef unsigned int tcflag_t;
typedef unsigned char cc_t;
struct termios32 {
    tcflag_t input_flags;
    tcflag_t output_flags;
    tcflag_t control_flags;
    tcflag_t local_flags;
    cc_t line;
    cc_t control_chars[19];
};

static long syscall0(long number)
{
    register long r0 __asm__("r0");
    register long r7 __asm__("r7") = number;
    __asm__ volatile("svc 0" : "=r"(r0) : "r"(r7) : "memory");
    return r0;
}

static long syscall1(long number, long a0)
{
    register long r0 __asm__("r0") = a0;
    register long r7 __asm__("r7") = number;
    __asm__ volatile("svc 0" : "+r"(r0) : "r"(r7) : "memory");
    return r0;
}

static long syscall2(long number, long a0, long a1)
{
    register long r0 __asm__("r0") = a0;
    register long r1 __asm__("r1") = a1;
    register long r7 __asm__("r7") = number;
    __asm__ volatile("svc 0" : "+r"(r0) : "r"(r1), "r"(r7) : "memory");
    return r0;
}

static long syscall3(long number, long a0, long a1, long a2)
{
    register long r0 __asm__("r0") = a0;
    register long r1 __asm__("r1") = a1;
    register long r2 __asm__("r2") = a2;
    register long r7 __asm__("r7") = number;
    __asm__ volatile("svc 0" : "+r"(r0) : "r"(r1), "r"(r2), "r"(r7) : "memory");
    return r0;
}

static usize text_length(const char *text)
{
    usize length = 0;
    while (text[length] != '\0') length++;
    return length;
}

static int text_equal(const char *left, const char *right)
{
    while (*left != '\0' && *right != '\0' && *left == *right) {
        left++;
        right++;
    }
    return *left == *right;
}

static char *append_text(char *output, const char *text)
{
    while (*text != '\0') *output++ = *text++;
    return output;
}

static char *append_span(char *output, const char *start, usize length)
{
    while (length-- > 0) *output++ = *start++;
    return output;
}

static char *append_unsigned(char *output, u32 value)
{
    static const u32 places[] = {
        1000000000, 100000000, 10000000, 1000000, 100000,
        10000, 1000, 100, 10, 1
    };
    usize place;
    int started = 0;
    for (place = 0; place < sizeof(places) / sizeof(places[0]); place++) {
        u8 digit = 0;
        while (value >= places[place]) {
            value -= places[place];
            digit++;
        }
        if (digit != 0 || started || places[place] == 1) {
            *output++ = (char)('0' + digit);
            started = 1;
        }
    }
    return output;
}

static void sleep_milliseconds(long milliseconds)
{
    struct timespec32 delay;
    /* All callers use sub-second delays; avoid the compiler's ARM divide
       runtime so this binary stays completely freestanding. */
    delay.seconds = 0;
    delay.nanoseconds = milliseconds * 1000000;
    syscall2(SYS_NANOSLEEP, (long)&delay, 0);
}

static void log_text(const char *text)
{
    syscall3(SYS_WRITE, 2, (long)text, (long)text_length(text));
}

static void touch_file(const char *path)
{
    long fd = syscall3(SYS_OPEN, (long)path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) syscall1(SYS_CLOSE, fd);
}

static const char *find_text(const char *haystack, const char *needle)
{
    usize needle_length = text_length(needle);
    if (needle_length == 0) return haystack;
    for (; *haystack != '\0'; haystack++) {
        usize i = 0;
        while (i < needle_length && haystack[i] == needle[i]) i++;
        if (i == needle_length) return haystack;
    }
    return 0;
}

static const char *json_value(const char *json, const char *quoted_key)
{
    const char *cursor = find_text(json, quoted_key);
    if (cursor == 0) return 0;
    cursor += text_length(quoted_key);
    while (*cursor == ' ' || *cursor == '\t' || *cursor == '\r' || *cursor == '\n') cursor++;
    if (*cursor++ != ':') return 0;
    while (*cursor == ' ' || *cursor == '\t' || *cursor == '\r' || *cursor == '\n') cursor++;
    return cursor;
}

static int json_string(const char *json, const char *key, char *output, usize capacity)
{
    const char *cursor = json_value(json, key);
    usize length = 0;
    if (cursor == 0 || *cursor++ != '"' || capacity == 0) return 0;
    while (*cursor != '\0' && *cursor != '"' && length + 1 < capacity) {
        if (*cursor == '\\' && cursor[1] != '\0') cursor++;
        output[length++] = *cursor++;
    }
    output[length] = '\0';
    return *cursor == '"';
}

static int json_integer(const char *json, const char *key, int fallback)
{
    const char *cursor = json_value(json, key);
    int sign = 1;
    int value = 0;
    int found = 0;
    if (cursor == 0) return fallback;
    if (*cursor == '-') {
        sign = -1;
        cursor++;
    }
    while (*cursor >= '0' && *cursor <= '9') {
        found = 1;
        value = value * 10 + (*cursor++ - '0');
    }
    return found ? value * sign : fallback;
}

static usize json_id(const char *json, char *output, usize capacity)
{
    const char *cursor = json_value(json, "\"id\"");
    usize length = 0;
    int quoted = 0;
    if (cursor == 0) cursor = json_value(json, "\"i\"");
    if (cursor == 0 || capacity == 0) {
        output[0] = '\0';
        return 0;
    }
    if (*cursor == '"') quoted = 1;
    while (*cursor != '\0' && length + 1 < capacity) {
        char byte = *cursor;
        if (!quoted && (byte == ',' || byte == '}')) break;
        output[length++] = byte;
        cursor++;
        if (quoted && byte == '"' && length > 1) break;
    }
    output[length] = '\0';
    return length;
}

static int write_all(int fd, const u8 *bytes, usize length)
{
    usize offset = 0;
    int retries = 0;
    while (offset < length) {
        long written = syscall3(SYS_WRITE, fd, (long)(bytes + offset), (long)(length - offset));
        if (written > 0) {
            offset += (usize)written;
            retries = 0;
            continue;
        }
        if (++retries > 200) return -1;
        sleep_milliseconds(5);
    }
    return 0;
}

static int send_json(int fd, const char *json)
{
    usize length = text_length(json);
    usize offset = 0;
    while (offset < length) {
        u8 report[REPORT_SIZE];
        usize chunk = length - offset;
        usize i;
        if (chunk > RPC_CHUNK) chunk = RPC_CHUNK;
        for (i = 0; i < REPORT_SIZE; i++) report[i] = 0;
        report[0] = REPORT_ID;
        report[1] = RPC_CHANNEL;
        report[2] = (u8)chunk;
        for (i = 0; i < chunk; i++) report[3 + i] = (u8)json[offset + i];
        if (write_all(fd, report, REPORT_SIZE) != 0) return -1;
        offset += chunk;
    }
    return 0;
}

static int send_v2_bytes(int fd, const u8 *bytes, usize length)
{
    usize offset = 0;
    while (offset < length) {
        u8 report[REPORT_SIZE];
        usize chunk = length - offset;
        usize i;
        if (chunk > RPC_CHUNK) chunk = RPC_CHUNK;
        for (i = 0; i < REPORT_SIZE; i++) report[i] = 0;
        report[0] = REPORT_ID;
        report[1] = V2_CHANNEL;
        report[2] = (u8)chunk;
        for (i = 0; i < chunk; i++) report[3 + i] = bytes[offset + i];
        if (write_all(fd, report, REPORT_SIZE) != 0) return -1;
        offset += chunk;
    }
    return 0;
}

static void send_result(int fd, const char *request, const char *result)
{
    char id[48];
    char message[512];
    char *output = message;
    if (json_id(request, id, sizeof(id)) == 0) return;
    output = append_text(output, "{\"id\":");
    output = append_text(output, id);
    output = append_text(output, ",\"result\":");
    output = append_text(output, result);
    output = append_text(output, "}\n");
    *output = '\0';
    send_json(fd, message);
}

static void send_method_error(int fd, const char *request)
{
    char id[48];
    char message[256];
    char *output = message;
    if (json_id(request, id, sizeof(id)) == 0) return;
    output = append_text(output, "{\"id\":");
    output = append_text(output, id);
    output = append_text(output, ",\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}\n");
    *output = '\0';
    send_json(fd, message);
}

static void forward_mk20_key(int fd, const char *request)
{
    char key[20];
    char message[320];
    char *output = message;
    int action;
    int agent;
    if (!json_string(request, "\"k\"", key, sizeof(key))) return;
    action = json_integer(request, "\"act\"", -1);
    agent = json_integer(request, "\"ag\"", -1);
    if (action < 0) return;

    output = append_text(output, "{\"method\":\"v.oai.hid\",\"params\":{\"k\":\"");
    output = append_text(output, key);
    output = append_text(output, "\",\"act\":");
    if (action > 9) return;
    *output++ = (char)('0' + action);
    if (agent >= 0) {
        if (agent > 9) return;
        output = append_text(output, ",\"ag\":");
        *output++ = (char)('0' + agent);
    }
    output = append_text(output, "}}\n");
    *output = '\0';
    send_json(fd, message);
}

static void process_request(int fd, const char *request)
{
    char method[48];
    if (!json_string(request, "\"method\"", method, sizeof(method)) &&
        !json_string(request, "\"m\"", method, sizeof(method))) {
        return;
    }
    if (text_equal(method, "v.mk20.hid")) {
        forward_mk20_key(fd, request);
    } else if (text_equal(method, "sys.version")) {
        send_result(fd, request, "{\"version\":\"1.0.0-mk20\"}");
    } else if (text_equal(method, "device.status")) {
        send_result(fd, request,
            "{\"version\":\"1.0.0-mk20\",\"profile_index\":0,\"layer_index\":0,"
            "\"battery\":100,\"is_charging\":true}");
    } else if (text_equal(method, "v.oai.thstatus") ||
               text_equal(method, "v.oai.rgbcfg") ||
               text_equal(method, "lights.preview")) {
        send_result(fd, request, "true");
    } else {
        send_method_error(fd, request);
    }
}

static int create_keyboard_pty(int hid_fd)
{
    int master;
    int slave;
    int unlock = 0;
    u32 pty_number = 0;
    char slave_path[48];
    char *cursor;
    long child;
    struct termios32 settings;
    /* Run the script through the shell instead of execve'ing the script
       itself. qt_app1 normally applies appLunch.sh's executable bit only
       after the TF-card hook returns, while this guarded hook intentionally
       remains in the foreground. */
    static char *const child_argv[] = { "/bin/sh", "/data/appLunch.sh", 0 };
    static char *const child_env[] = {
        "PATH=/bin:/sbin:/usr/bin:/usr/sbin",
        "HOME=/root",
        0
    };

    master = (int)syscall3(SYS_OPEN, (long)"/dev/ptmx", O_RDWR | O_NOCTTY, 0);
    if (master < 0) return -1;
    if (syscall3(SYS_IOCTL, master, TIOCSPTLCK, (long)&unlock) < 0 ||
        syscall3(SYS_IOCTL, master, TIOCGPTN, (long)&pty_number) < 0) {
        syscall1(SYS_CLOSE, master);
        return -1;
    }

    cursor = append_text(slave_path, "/dev/pts/");
    cursor = append_unsigned(cursor, pty_number);
    *cursor = '\0';
    slave = (int)syscall3(SYS_OPEN, (long)slave_path, O_RDWR | O_NOCTTY, 0);
    if (slave < 0) {
        syscall1(SYS_CLOSE, master);
        return -1;
    }
    if (syscall3(SYS_IOCTL, slave, TCGETS, (long)&settings) >= 0) {
        settings.input_flags = 0;
        settings.output_flags = 0;
        settings.local_flags = 0;
        settings.control_flags |= 0x880; /* CLOCAL | CREAD */
        settings.control_chars[5] = 0;   /* VTIME */
        settings.control_chars[6] = 1;   /* VMIN */
        syscall3(SYS_IOCTL, slave, TCSETS, (long)&settings);
    }
    syscall2(SYS_CHMOD, (long)slave_path, 0666);

    syscall1(SYS_UNLINK, (long)"/dev/ttyGS0");
    if (syscall2(SYS_SYMLINK, (long)slave_path, (long)"/dev/ttyGS0") < 0) {
        syscall1(SYS_CLOSE, slave);
        syscall1(SYS_CLOSE, master);
        return -1;
    }

    child = syscall0(SYS_FORK);
    if (child == 0) {
        syscall1(SYS_CLOSE, slave);
        syscall1(SYS_CLOSE, master);
        syscall1(SYS_CLOSE, hid_fd);
        syscall3(SYS_EXECVE, (long)"/bin/sh",
                 (long)child_argv, (long)child_env);
        syscall1(SYS_EXIT, 127);
        for (;;) {}
    }
    if (child < 0) {
        syscall1(SYS_UNLINK, (long)"/dev/ttyGS0");
        syscall1(SYS_CLOSE, slave);
        syscall1(SYS_CLOSE, master);
        return -1;
    }
    /* Keep the slave open in the bridge so poll(master) cannot report HUP
       during the short window before appLunch opens /dev/ttyGS0. */
    syscall3(SYS_FCNTL, master, F_SETFL, O_NONBLOCK);
    touch_file("/tmp/codex-hid-pty-ready");
    return master;
}

static void process_hid_report(int hid_fd, int pty_fd, const u8 *report, usize count,
                               char *rpc, usize *rpc_length)
{
    usize base = 0;
    usize length;
    usize i;
    if (count == 0) return;
    if (report[0] == REPORT_ID) base = 1;
    if (count < base + 2) return;
    length = report[base + 1];
    if (length > RPC_CHUNK) length = RPC_CHUNK;
    if (length + base + 2 > count) length = count - base - 2;

    if (report[base] == V2_CHANNEL) {
        if (length > 0) write_all(pty_fd, report + base + 2, length);
        return;
    }
    if (report[base] != RPC_CHANNEL) return;
    for (i = 0; i < length; i++) {
        char byte = (char)report[base + 2 + i];
        if (byte == '\n') {
            rpc[*rpc_length] = '\0';
            if (*rpc_length > 0) process_request(hid_fd, rpc);
            *rpc_length = 0;
        } else if (byte != '\r' && byte != '\0') {
            if (*rpc_length + 1 < 2048) rpc[(*rpc_length)++] = byte;
            else *rpc_length = 0;
        }
    }
}

static int bridge_main(void)
{
    static char rpc[2048];
    usize rpc_length = 0;
    int hid_fd;
    int pty_fd;
    log_text("codex-micro-bridge: waiting for /dev/codexhidg0\n");
    for (;;) {
        hid_fd = (int)syscall3(SYS_OPEN, (long)"/dev/codexhidg0", O_RDWR, 0);
        if (hid_fd >= 0) break;
        sleep_milliseconds(500);
    }
    pty_fd = create_keyboard_pty(hid_fd);
    if (pty_fd < 0) {
        log_text("codex-micro-bridge: PTY setup failed\n");
        syscall1(SYS_CLOSE, hid_fd);
        return 2;
    }
    log_text("codex-micro-bridge: online\n");

    for (;;) {
        struct pollfd32 descriptors[2];
        long ready;
        descriptors[0].fd = hid_fd;
        descriptors[0].events = POLLIN;
        descriptors[0].revents = 0;
        descriptors[1].fd = pty_fd;
        descriptors[1].events = POLLIN;
        descriptors[1].revents = 0;
        ready = syscall3(SYS_POLL, (long)descriptors, 2, 500);
        if (ready < 0) continue;
        if (descriptors[0].revents & (POLLERR | POLLHUP | POLLNVAL)) break;
        if (descriptors[1].revents & (POLLERR | POLLHUP | POLLNVAL)) break;
        if (descriptors[0].revents & POLLIN) {
            u8 report[REPORT_SIZE];
            long count = syscall3(SYS_READ, hid_fd, (long)report, REPORT_SIZE);
            if (count > 0) {
                process_hid_report(hid_fd, pty_fd, report, (usize)count,
                                   rpc, &rpc_length);
            }
        }
        if (descriptors[1].revents & POLLIN) {
            u8 bytes[RPC_CHUNK];
            long count = syscall3(SYS_READ, pty_fd, (long)bytes, sizeof(bytes));
            if (count > 0) {
                touch_file("/tmp/codex-v2-live");
                if (send_v2_bytes(hid_fd, bytes, (usize)count) != 0) break;
            }
        }
    }
    syscall1(SYS_CLOSE, pty_fd);
    syscall1(SYS_CLOSE, hid_fd);
    syscall1(SYS_UNLINK, (long)"/dev/ttyGS0");
    return 1;
}

__attribute__((noreturn)) void _start(void)
{
    int result = bridge_main();
    syscall1(SYS_EXIT, result);
    for (;;) {}
}
