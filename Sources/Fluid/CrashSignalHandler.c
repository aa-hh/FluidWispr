#include "CrashSignalHandler.h"

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ucontext.h>
#include <time.h>
#include <unistd.h>

// Everything the signal handler touches is allocated before a crash: the image
// table below, the record file descriptor and the saved signal actions. The
// handler itself only reads memory, formats numbers into stack buffers and
// calls write(), sigaction(), raise(), sleep(), clock_gettime() and the
// pthread queries for the current thread (stack bounds, main thread, id).

#define FV_CRASH_MAX_FRAMES 128
#define FV_CRASH_MAX_IMAGES 4096

typedef struct {
    _Atomic uintptr_t start; // 0 once the image is unloaded
    uintptr_t end;
    uint8_t uuid[16];
    const char *path; // owned by dyld for as long as the image stays loaded
} FVCrashImage;

static FVCrashImage fv_images[FV_CRASH_MAX_IMAGES];
static _Atomic uint32_t fv_image_count = 0;

static const int fv_crash_signals[] = { SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGSYS, SIGTRAP };
#define FV_CRASH_SIGNAL_COUNT (sizeof(fv_crash_signals) / sizeof(fv_crash_signals[0]))

static struct sigaction fv_previous_actions[NSIG];
static int fv_record_fd = -1;
static _Atomic uintptr_t fv_crashing_thread = 0;

// MARK: - Image table, filled outside signal context

static void fv_image_added(const struct mach_header *header, intptr_t slide) {
    if (header->magic != MH_MAGIC_64) {
        return;
    }
    uintptr_t start = 0;
    uintptr_t end = 0;
    uint8_t uuid[16] = { 0 };
    const uint8_t *command = (const uint8_t *)header + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *load = (const struct load_command *)command;
        if (load->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
            if (strncmp(segment->segname, SEG_TEXT, sizeof(segment->segname)) == 0) {
                start = (uintptr_t)segment->vmaddr + (uintptr_t)slide;
                end = start + (uintptr_t)segment->vmsize;
            }
        } else if (load->cmd == LC_UUID) {
            memcpy(uuid, ((const struct uuid_command *)command)->uuid, sizeof(uuid));
        }
        command += load->cmdsize;
    }
    if (start == 0) {
        return;
    }

    Dl_info info;
    const char *path = dladdr(header, &info) != 0 ? info.dli_fname : NULL;

    uint32_t index = atomic_fetch_add(&fv_image_count, 1);
    if (index >= FV_CRASH_MAX_IMAGES) {
        atomic_store(&fv_image_count, FV_CRASH_MAX_IMAGES);
        return;
    }
    FVCrashImage *image = &fv_images[index];
    image->end = end;
    memcpy(image->uuid, uuid, sizeof(uuid));
    image->path = path;
    // Publish last so the handler never sees a start without its other fields.
    atomic_store_explicit(&image->start, start, memory_order_release);
}

static void fv_image_removed(const struct mach_header *header, intptr_t slide) {
    (void)slide;
    uintptr_t address = (uintptr_t)header;
    uint32_t count = atomic_load(&fv_image_count);
    for (uint32_t i = 0; i < count && i < FV_CRASH_MAX_IMAGES; i++) {
        uintptr_t start = atomic_load_explicit(&fv_images[i].start, memory_order_acquire);
        if (start != 0 && address >= start && address < fv_images[i].end) {
            atomic_store(&fv_images[i].start, 0);
        }
    }
}

// MARK: - Signal-safe output

static void fv_write_all(const char *bytes, size_t length) {
    while (length > 0) {
        ssize_t written = write(fv_record_fd, bytes, length);
        if (written < 0) {
            if (errno == EINTR) {
                continue;
            }
            return;
        }
        bytes += written;
        length -= (size_t)written;
    }
}

typedef struct {
    char bytes[1280];
    size_t length;
} FVLine;

static void fv_line_text(FVLine *line, const char *text) {
    while (*text != '\0' && line->length < sizeof(line->bytes) - 1) {
        line->bytes[line->length++] = *text++;
    }
}

static void fv_line_hex(FVLine *line, uint64_t value) {
    static const char digits[] = "0123456789abcdef";
    fv_line_text(line, "0x");
    for (int shift = 60; shift >= 0; shift -= 4) {
        if (line->length < sizeof(line->bytes) - 1) {
            line->bytes[line->length++] = digits[(value >> shift) & 0xf];
        }
    }
}

static void fv_line_decimal(FVLine *line, int64_t value) {
    char digits[24];
    int count = 0;
    uint64_t magnitude = value < 0 ? (uint64_t)(-(value + 1)) + 1 : (uint64_t)value;
    do {
        digits[count++] = (char)('0' + magnitude % 10);
        magnitude /= 10;
    } while (magnitude > 0);
    if (value < 0) {
        fv_line_text(line, "-");
    }
    while (count > 0 && line->length < sizeof(line->bytes) - 1) {
        line->bytes[line->length++] = digits[--count];
    }
}

static void fv_line_end(FVLine *line) {
    line->bytes[line->length++] = '\n';
    fv_write_all(line->bytes, line->length);
    line->length = 0;
}

static void fv_write_number_line(const char *key, int64_t value) {
    FVLine line = { .length = 0 };
    fv_line_text(&line, key);
    fv_line_text(&line, " ");
    fv_line_decimal(&line, value);
    fv_line_end(&line);
}

static void fv_write_hex_line(const char *key, uint64_t value) {
    FVLine line = { .length = 0 };
    fv_line_text(&line, key);
    fv_line_text(&line, " ");
    fv_line_hex(&line, value);
    fv_line_end(&line);
}

// MARK: - Stack walk

// Return addresses saved by arm64e system libraries can carry a pointer
// authentication signature above the 47-bit user address range. Strip it so
// the address matches the image ranges.
static uintptr_t fv_strip_pointer(uintptr_t value) {
#if defined(__arm64__)
    return value & 0x00007fffffffffffULL;
#else
    return value;
#endif
}

static size_t fv_collect_frames(const ucontext_t *context, uintptr_t *frames, size_t capacity) {
    if (context == NULL || context->uc_mcontext == NULL) {
        return 0;
    }
    uintptr_t pc;
    uintptr_t fp;
    uintptr_t lr = 0;
#if defined(__arm64__)
    pc = (uintptr_t)arm_thread_state64_get_pc(context->uc_mcontext->__ss);
    fp = (uintptr_t)arm_thread_state64_get_fp(context->uc_mcontext->__ss);
    lr = (uintptr_t)arm_thread_state64_get_lr(context->uc_mcontext->__ss);
#elif defined(__x86_64__)
    pc = (uintptr_t)context->uc_mcontext->__ss.__rip;
    fp = (uintptr_t)context->uc_mcontext->__ss.__rbp;
#else
    return 0;
#endif

    size_t count = 0;
    frames[count++] = fv_strip_pointer(pc);

    // Only follow frame pointers that stay inside this thread's stack, so a
    // corrupted chain ends the walk instead of faulting inside the handler.
    pthread_t self = pthread_self();
    uintptr_t stackTop = (uintptr_t)pthread_get_stackaddr_np(self);
    uintptr_t stackBottom = stackTop - (uintptr_t)pthread_get_stacksize_np(self);

    bool lrPending = lr != 0;
    while (count < capacity && fp != 0 && (fp & 0x7) == 0 && fp >= stackBottom && fp + 2 * sizeof(uintptr_t) <= stackTop) {
        const uintptr_t *record = (const uintptr_t *)fp;
        uintptr_t next = record[0];
        uintptr_t returnAddress = fv_strip_pointer(record[1]);
        if (returnAddress == 0) {
            break;
        }
        // A leaf function never saves its caller's address to the stack, so
        // the link register holds the only copy. Add it unless the walk found
        // the same address in the first saved frame.
        if (lrPending) {
            lrPending = false;
            uintptr_t strippedLr = fv_strip_pointer(lr);
            if (strippedLr != returnAddress && count < capacity) {
                frames[count++] = strippedLr;
            }
            if (count >= capacity) {
                break;
            }
        }
        frames[count++] = returnAddress;
        if (next <= fp) {
            break;
        }
        fp = next;
    }
    if (lrPending && count < capacity) {
        frames[count++] = fv_strip_pointer(lr);
    }
    return count;
}

// MARK: - Handler

static void fv_write_record(int signalNumber, const siginfo_t *info, const ucontext_t *context) {
    // Header first, so a fault later in the walk still leaves the signal on disk.
    fv_write_number_line("signal", signalNumber);
    fv_write_number_line("code", info != NULL ? info->si_code : 0);
    fv_write_hex_line("address", info != NULL ? (uint64_t)(uintptr_t)info->si_addr : 0);
    struct timespec now;
    if (clock_gettime(CLOCK_REALTIME, &now) == 0) {
        fv_write_number_line("time", (int64_t)now.tv_sec);
    }
    fv_write_number_line("main", pthread_main_np());
    fv_write_number_line("thread", (int64_t)pthread_mach_thread_np(pthread_self()));

    uintptr_t frames[FV_CRASH_MAX_FRAMES];
    size_t frameCount = fv_collect_frames(context, frames, FV_CRASH_MAX_FRAMES);
    for (size_t i = 0; i < frameCount; i++) {
        fv_write_hex_line("frame", frames[i]);
    }

    // Only the images that hold a frame, to keep the record short.
    uint32_t imageCount = atomic_load(&fv_image_count);
    for (uint32_t i = 0; i < imageCount && i < FV_CRASH_MAX_IMAGES; i++) {
        const FVCrashImage *image = &fv_images[i];
        uintptr_t start = atomic_load_explicit(&image->start, memory_order_acquire);
        if (start == 0) {
            continue;
        }
        bool used = false;
        for (size_t f = 0; f < frameCount && !used; f++) {
            used = frames[f] >= start && frames[f] < image->end;
        }
        if (!used) {
            continue;
        }
        FVLine line = { .length = 0 };
        fv_line_text(&line, "image ");
        fv_line_hex(&line, start);
        fv_line_text(&line, " ");
        fv_line_hex(&line, image->end);
        fv_line_text(&line, " ");
        static const char digits[] = "0123456789abcdef";
        for (size_t b = 0; b < sizeof(image->uuid); b++) {
            char pair[3] = { digits[image->uuid[b] >> 4], digits[image->uuid[b] & 0xf], '\0' };
            fv_line_text(&line, pair);
        }
        fv_line_text(&line, " ");
        fv_line_text(&line, image->path != NULL ? image->path : "?");
        fv_line_end(&line);
    }
    fv_write_all("end\n", 4);
}

static void fv_restore_and_reraise(int signalNumber) {
    sigaction(signalNumber, &fv_previous_actions[signalNumber], NULL);
    // The signal stays blocked until this handler returns, then the previous
    // handler or the default action (terminate) runs. A hardware fault would
    // also repeat on return; raising covers abort() and kill as well.
    raise(signalNumber);
}

static void fv_crash_signal_handler(int signalNumber, siginfo_t *info, void *rawContext) {
    int savedErrno = errno;
    uintptr_t self = (uintptr_t)pthread_self();
    uintptr_t expected = 0;
    if (!atomic_compare_exchange_strong(&fv_crashing_thread, &expected, self)) {
        if (expected != self) {
            // Another thread is writing its record. Give it time to finish;
            // its re-raise ends the process.
            for (int i = 0; i < 4; i++) {
                sleep(1);
            }
        }
        // Same thread faulted inside the handler, or the writer never
        // finished: stop recording and let the signal take effect.
        fv_restore_and_reraise(signalNumber);
        errno = savedErrno;
        return;
    }
    if (fv_record_fd >= 0) {
        fv_write_record(signalNumber, info, (const ucontext_t *)rawContext);
    }
    fv_restore_and_reraise(signalNumber);
    errno = savedErrno;
}

// MARK: - Setup

bool fv_crash_handler_install(const char *recordPath, const char *preamble) {
    static bool installed = false;
    if (installed) {
        return fv_record_fd >= 0;
    }
    int fd = open(recordPath, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND | O_CLOEXEC, S_IRUSR | S_IWUSR);
    if (fd < 0) {
        return false;
    }
    installed = true;
    fv_record_fd = fd;
    fv_write_all("fluidcrash 1\n", 13);
    if (preamble != NULL) {
        fv_write_all(preamble, strlen(preamble));
        if (preamble[0] != '\0' && preamble[strlen(preamble) - 1] != '\n') {
            fv_write_all("\n", 1);
        }
    }
    fv_write_number_line("pid", getpid());

    _dyld_register_func_for_add_image(fv_image_added);
    _dyld_register_func_for_remove_image(fv_image_removed);

    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_sigaction = fv_crash_signal_handler;
    action.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&action.sa_mask);
    for (size_t i = 0; i < FV_CRASH_SIGNAL_COUNT; i++) {
        sigaction(fv_crash_signals[i], &action, &fv_previous_actions[fv_crash_signals[i]]);
    }
    return true;
}

void fv_crash_handler_install_alt_stack(void) {
    static bool installed = false;
    if (installed) {
        return;
    }
    stack_t stack;
    stack.ss_size = SIGSTKSZ;
    stack.ss_sp = malloc(stack.ss_size);
    stack.ss_flags = 0;
    if (stack.ss_sp == NULL) {
        return;
    }
    if (sigaltstack(&stack, NULL) == 0) {
        installed = true;
    } else {
        free(stack.ss_sp);
    }
}

void fv_crash_handler_write_note(const char *note) {
    if (fv_record_fd < 0 || note == NULL) {
        return;
    }
    FVLine line = { .length = 0 };
    fv_line_text(&line, "note ");
    for (const char *c = note; *c != '\0' && line.length < sizeof(line.bytes) - 1; c++) {
        line.bytes[line.length++] = (*c == '\n' || *c == '\r') ? ' ' : *c;
    }
    fv_line_end(&line);
}
