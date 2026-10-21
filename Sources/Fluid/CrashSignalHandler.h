#ifndef FLUID_CRASH_SIGNAL_HANDLER_H
#define FLUID_CRASH_SIGNAL_HANDLER_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opens `recordPath` for this run and installs handlers for fatal signals.
///
/// The handler only calls async-signal-safe functions: it writes raw numbers
/// (signal, fault address, return addresses, loaded image ranges) to the file
/// descriptor opened here. `CrashReportRecovery` turns that record into a
/// readable report on the next launch. `preamble` is written immediately, so
/// it may hold anything the report needs that is unsafe to read at crash time
/// (app version, macOS version). Returns false if the file cannot be opened.
bool fv_crash_handler_install(const char *recordPath, const char *preamble);

/// Gives the calling thread a separate stack for the signal handler, so a
/// stack overflow on that thread can still be recorded. Call on the main thread.
void fv_crash_handler_install_alt_stack(void);

/// Appends one `note` line to the record. Not for signal context; used by the
/// uncaught exception handler, which runs before the abort signal.
void fv_crash_handler_write_note(const char *note);

#ifdef __cplusplus
}
#endif

#endif
