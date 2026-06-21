/*
 * ios_early_crash_handler.mm
 *
 * Installs Unix signal handlers using __attribute__((constructor)) so they
 * are active before main() and before any C++ static initializers.
 *
 * On a fatal signal the handler writes to TWO places (no UI needed):
 *   1. Documents/pvz_early_crash.txt  — readable via Files app / iTunes
 *   2. stderr / NSLog                 — readable in Xcode console
 *
 * This gives us a guaranteed crash trace even when the crash happens during
 * dylib loading, ObjC +load, or C++ static init — all before main().
 */

#import <Foundation/Foundation.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <string.h>
#include <stdio.h>
#include <execinfo.h>   // backtrace / backtrace_symbols_fd — async-signal-safe

// ---------------------------------------------------------------------------
// Signal-safe file writer
// Only uses async-signal-safe syscalls (open/write/close).
// ---------------------------------------------------------------------------
static void signal_write_str(int fd, const char* s)
{
    if (!s) return;
    size_t len = 0;
    while (s[len]) ++len;
    while (len > 0) {
        ssize_t n = write(fd, s, len);
        if (n <= 0) break;
        s   += n;
        len -= (size_t)n;
    }
}

// Opens (or creates/appends) Documents/pvz_early_crash.txt in a
// signal-safe way using only POSIX syscalls.
static int open_crash_log_fd()
{
    // NSSearchPathForDirectoriesInDomains is NOT async-signal-safe, so we
    // use a path we cached at startup (see pvz_cache_docs_path below).
    extern const char* pvz_cached_docs_path; // defined below
    if (!pvz_cached_docs_path || pvz_cached_docs_path[0] == '\0')
        return -1;

    // Build path: <docs>/pvz_early_crash.txt
    // We need a fixed-size buffer — Documents paths on iOS are ~60 chars.
    static char path[1024];
    size_t dlen = 0;
    const char* d = pvz_cached_docs_path;
    while (d[dlen] && dlen < sizeof(path) - 32) { path[dlen] = d[dlen]; ++dlen; }
    const char* suffix = "/pvz_early_crash.txt";
    size_t slen = 0;
    while (suffix[slen] && dlen + slen < sizeof(path) - 1) {
        path[dlen + slen] = suffix[slen]; ++slen;
    }
    path[dlen + slen] = '\0';

    return open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
}

// Signal names for common fatal signals
static const char* signal_name(int sig)
{
    switch (sig) {
        case SIGABRT: return "SIGABRT";
        case SIGSEGV: return "SIGSEGV";
        case SIGBUS:  return "SIGBUS";
        case SIGILL:  return "SIGILL";
        case SIGFPE:  return "SIGFPE";
        case SIGTRAP: return "SIGTRAP";
        default:      return "SIG???";
    }
}

// ---------------------------------------------------------------------------
// The actual signal handler (async-signal-safe as much as possible)
// ---------------------------------------------------------------------------
static void pvz_signal_handler(int sig)
{
    // Write to stderr first (shows in Xcode console)
    const char* sname = signal_name(sig);
    signal_write_str(STDERR_FILENO, "\n[PvZ FATAL SIGNAL] ");
    signal_write_str(STDERR_FILENO, sname);
    signal_write_str(STDERR_FILENO, "\nStack trace:\n");

    // backtrace_symbols_fd is async-signal-safe
    void* frames[64];
    int   count = backtrace(frames, 64);
    backtrace_symbols_fd(frames, count, STDERR_FILENO);
    signal_write_str(STDERR_FILENO, "\n");

    // Write to Documents/pvz_early_crash.txt
    int fd = open_crash_log_fd();
    if (fd >= 0) {
        signal_write_str(fd, "[PvZ FATAL SIGNAL] ");
        signal_write_str(fd, sname);
        signal_write_str(fd, "\nStack trace:\n");
        backtrace_symbols_fd(frames, count, fd);
        signal_write_str(fd, "\n");
        close(fd);
    }

    // Re-raise with default handler so the OS records a proper crash report
    signal(sig, SIG_DFL);
    raise(sig);
}

// ---------------------------------------------------------------------------
// Documents path cache — filled by the constructor below (before main)
// ---------------------------------------------------------------------------
const char* pvz_cached_docs_path = nullptr;
static char pvz_docs_path_buf[1024];

// ---------------------------------------------------------------------------
// Constructor — runs before main() and before most C++ static inits
// Priority 101 = very early (lower number = earlier; 0-100 reserved by OS)
// ---------------------------------------------------------------------------
__attribute__((constructor(101)))
static void pvz_install_early_crash_handler()
{
    // 1. Cache the Documents path (NSFoundation is safe here)
    @autoreleasepool {
        NSArray* paths = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES);
        if (paths.count > 0) {
            const char* utf8 = [paths[0] UTF8String];
            if (utf8) {
                strncpy(pvz_docs_path_buf, utf8, sizeof(pvz_docs_path_buf) - 1);
                pvz_docs_path_buf[sizeof(pvz_docs_path_buf) - 1] = '\0';
                pvz_cached_docs_path = pvz_docs_path_buf;
            }
        }
    }

    // 2. Write a "binary started" sentinel so we know the executable loaded
    int fd = open_crash_log_fd();
    if (fd >= 0) {
        signal_write_str(fd, "[PvZ EARLY INIT] binary loaded, installing signal handlers\n");
        close(fd);
    }
    // Also to stderr (Xcode console)
    signal_write_str(STDERR_FILENO,
        "[PvZ EARLY INIT] binary loaded, installing signal handlers\n");

    // 3. Install signal handlers
    signal(SIGABRT, pvz_signal_handler);
    signal(SIGSEGV, pvz_signal_handler);
    signal(SIGBUS,  pvz_signal_handler);
    signal(SIGILL,  pvz_signal_handler);
    signal(SIGFPE,  pvz_signal_handler);
    signal(SIGTRAP, pvz_signal_handler);
}
