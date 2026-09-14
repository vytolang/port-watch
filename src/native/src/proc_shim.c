/* port-watch — the /proc reads that the Vyto builtins cannot do safely.
 *
 * Three things live here and nothing else:
 *
 *   1. readlink.  /proc/<pid>/fd/<n> is a symlink reading "socket:[12345]",
 *      and Vyto has no readlink builtin.
 *
 *   2. A directory walk that does not abort.  The `listdir` builtin panics
 *      when it cannot open the directory (runtime/vyto_rt.c, vt_dir_list),
 *      and under /proc that is the normal case, not an error: another user's
 *      /proc/<pid>/fd is 0500 and owned by them, and any pid at all can exit
 *      between being listed and being opened.  A tool that aborted on either
 *      would be unusable as a non-root user.
 *
 *   3. The fd->inode scan itself.  Done here rather than in Vyto because it
 *      is the hot path: a few thousand readlink calls per refresh, and
 *      crossing the FFI boundary once per fd would dominate the runtime.
 *      Vyto passes down the set of inodes it actually cares about (every
 *      listening socket, from /proc/net/*), so this returns only matches and
 *      the caller never sees the thousands of pipes and regular files.
 *
 * Nothing here allocates through the Vyto runtime: results go into a caller
 * supplied buffer as text, which keeps the ownership rules trivial — the
 * caller owns its buffer and there is nothing to free.
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#ifndef _WIN32
#include <unistd.h>
#include <dirent.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <pwd.h>
#endif

/* ---- 1. readlink ------------------------------------------------------- */

/* Writes the link target into `buf` as a NUL-terminated string and returns
 * its length, or 0 when the path is not a link / cannot be read.  0 rather
 * than -1 because every caller here treats "no target" and "failed" the same
 * way, and a single sentinel keeps the Vyto side free of errno handling. */
int pw_readlink(const char *path, char *buf, int cap) {
#ifdef _WIN32
    (void)path; (void)buf; (void)cap;
    return 0;
#else
    if (!path || !buf || cap <= 1) return 0;
    ssize_t n = readlink(path, buf, (size_t)cap - 1);
    if (n <= 0) return 0;
    buf[n] = '\0';
    return (int)n;
#endif
}

/* ---- 2. a listdir that returns emptiness instead of dying -------------- */

/* Entry names joined by '\n'.  Returns the count, or -1 when the directory
 * could not be opened at all — which the caller distinguishes from 0 ("opened
 * fine, nothing in it") because for /proc/<pid>/fd the difference is exactly
 * "not permitted to look" versus "no open sockets". */
int pw_listdir(const char *path, char *buf, int cap, int *truncated) {
#ifdef _WIN32
    (void)path; (void)buf; (void)cap;
    if (truncated) *truncated = 0;
    return -1;
#else
    if (truncated) *truncated = 0;
    if (!path || !buf || cap <= 1) return -1;
    DIR *d = opendir(path);
    if (!d) return -1;

    int used = 0, count = 0;
    struct dirent *de;
    while ((de = readdir(d))) {
        if (de->d_name[0] == '.' &&
            (de->d_name[1] == '\0' ||
             (de->d_name[1] == '.' && de->d_name[2] == '\0'))) continue;
        int len = (int)strlen(de->d_name);
        /* +1 for the separator, +1 for the final NUL */
        if (used + len + 2 > cap) { if (truncated) *truncated = 1; break; }
        if (used > 0) buf[used++] = '\n';
        memcpy(buf + used, de->d_name, (size_t)len);
        used += len;
        count++;
    }
    buf[used] = '\0';
    closedir(d);
    return count;
#endif
}

/* Read a whole small /proc file.  The builtin `readfile` panics on a missing
 * path, and every /proc/<pid> file can vanish mid-scan, so this returns a
 * length and never complains.  /proc files report st_size 0, which is why
 * this reads until EOF rather than stat-ing first. */
int pw_readfile(const char *path, char *buf, int cap) {
    if (!path || !buf || cap <= 1) return 0;
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    size_t n = fread(buf, 1, (size_t)cap - 1, f);
    fclose(f);
    buf[n] = '\0';
    return (int)n;
}

/* Read /proc/<pid>/cmdline, whose arguments are NUL-separated.
 *
 * This needs its own entry point because the separators are the payload: the
 * Vyto side receives a length-counted string that keeps every embedded NUL,
 * so it cannot tell argv[0] from the rest, and searching the whole buffer for
 * a '/' finds one inside some later argument. Splitting here, where the byte
 * count and the NULs are both in hand, is the only place it can be done
 * correctly.
 *
 * `full` picks the form: 0 gives argv[0] alone, 1 gives the whole command
 * line with the NULs turned into spaces.
 *
 * Returns the length written, or 0 for a kernel thread (whose cmdline is
 * genuinely empty — the caller falls back to comm).
 */
int pw_cmdline(int pid, int full, char *buf, int cap) {
    if (!buf || cap <= 1) return 0;
    char path[64];
    snprintf(path, sizeof path, "/proc/%d/cmdline", pid);

    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    size_t n = fread(buf, 1, (size_t)cap - 1, f);
    fclose(f);
    if (n == 0) { buf[0] = '\0'; return 0; }

    if (!full) {
        /* argv[0] ends at the first NUL -- USUALLY.  Some programs rewrite
         * their own argv into one flat space-separated string (Chromium and
         * anything else that rewrites the area to set a process title), so
         * the buffer can contain no NUL at all until the very end.  Stopping
         * only at a NUL therefore returns the entire command line for exactly
         * the processes with the longest ones.
         *
         * Stopping at the first NUL OR the first space handles both layouts.
         * A genuine space inside argv[0] -- a program installed under a path
         * with a space in it -- truncates to the first word, which is the
         * right trade: it is vanishingly rare, and the alternative misreads
         * every Chromium process on the machine. */
        size_t end = 0;
        while (end < n && buf[end] != '\0' && buf[end] != ' ') end++;
        buf[end] = '\0';
        return (int)end;
    }

    /* Whole line: separators become spaces. The final NUL is dropped rather
     * than becoming a trailing space. */
    size_t end = n;
    while (end > 0 && buf[end - 1] == '\0') end--;
    for (size_t i = 0; i < end; i++) if (buf[i] == '\0') buf[i] = ' ';
    buf[end] = '\0';
    return (int)end;
}

/* Flush stdout.
 *
 * Needed by the watch loop: stdout is block-buffered whenever it is not a
 * terminal, so a redirected or piped watch emits nothing until the buffer
 * fills -- and a watch is normally ended by a signal, which discards it.  The
 * whole session then produces an empty file. */
void pw_flush(void) { fflush(stdout); }

/* Is `pid` a live process, as opposed to merely a surviving /proc entry?
 *
 * kill(pid, 0) is the usual liveness probe and it is WRONG here: a zombie --
 * a process that has exited but whose parent has not yet wait()ed for it --
 * still answers kill(pid, 0) successfully, because the pid is still allocated.
 * It has, however, already released every file descriptor it held, so the
 * port is free while the probe still says "alive".
 *
 * That is not a corner case for this tool.  The parent is very often a shell
 * sitting in a command substitution or otherwise not reaping, which is
 * exactly the shape of `port-watch -k` run from a script, so a kill would
 * routinely be reported as "ignored the signal" a moment after it worked.
 *
 * The state field is the third in /proc/<pid>/stat -- but the second field is
 * the executable name in parentheses AND MAY ITSELF CONTAIN SPACES OR
 * PARENTHESES, so the fields cannot simply be split on whitespace.  The state
 * is the first non-space character after the LAST ')' in the line.
 *
 * Returns 1 for a live process, 0 for a zombie or one that is gone.
 */
int pw_alive(int pid) {
    char path[64], buf[512];
    snprintf(path, sizeof path, "/proc/%d/stat", pid);
    FILE *f = fopen(path, "rb");
    if (!f) return 0;                      /* gone entirely */
    size_t n = fread(buf, 1, sizeof buf - 1, f);
    fclose(f);
    if (n == 0) return 0;
    buf[n] = '\0';

    const char *close = strrchr(buf, ')');
    if (!close) return 0;
    const char *p = close + 1;
    while (*p == ' ') p++;
    if (*p == '\0') return 0;
    /* 'Z' is a zombie; 'X' and 'x' are the dead states a kernel may report. */
    return (*p != 'Z' && *p != 'X' && *p != 'x');
}

/* The owning uid of a path, or -1.  Used on /proc/<pid> to attribute a socket
 * whose fd directory we are not allowed to open. */
int pw_path_uid(const char *path) {
#ifdef _WIN32
    (void)path;
    return -1;
#else
    struct stat st;
    if (!path || stat(path, &st) != 0) return -1;
    return (int)st.st_uid;
#endif
}

/* Username for a uid, into buf.  Falls back to the decimal uid when there is
 * no passwd entry (a container with no /etc/passwd, an LDAP miss). */
int pw_username(int uid, char *buf, int cap) {
    if (!buf || cap <= 1) return 0;
#ifndef _WIN32
    struct passwd *pw = getpwuid((uid_t)uid);
    if (pw && pw->pw_name) {
        int len = (int)strlen(pw->pw_name);
        if (len > cap - 1) len = cap - 1;
        memcpy(buf, pw->pw_name, (size_t)len);
        buf[len] = '\0';
        return len;
    }
#endif
    return snprintf(buf, (size_t)cap, "%d", uid);
}

/* Our own uid, so the caller can tell "cannot read" from "not mine". */
int pw_self_uid(void) {
#ifdef _WIN32
    return -1;
#else
    return (int)getuid();
#endif
}

/* ---- 3. the fd scan ---------------------------------------------------- */

/* Scan one process's open file descriptors for sockets whose inode appears in
 * `wanted` (a sorted array of `nwanted` inodes).  Matches are appended to
 * `out` as "inode\n" lines.
 *
 * Returns the number of matches, or -1 if /proc/<pid>/fd could not be opened,
 * which the caller reports as an unresolvable owner rather than a blank.
 *
 * The sorted `wanted` set is what keeps this cheap: a process with 4000 open
 * files costs 4000 readlinks and 4000 binary searches over a list that is
 * typically a few dozen long, and allocates nothing.
 */
static int inode_wanted(const long *wanted, int n, long v) {
    int lo = 0, hi = n - 1;
    while (lo <= hi) {
        int mid = lo + (hi - lo) / 2;
        if (wanted[mid] == v) return 1;
        if (wanted[mid] < v) lo = mid + 1; else hi = mid - 1;
    }
    return 0;
}

int pw_scan_pid_fds(int pid, const long *wanted, int nwanted,
                    char *out, int outcap) {
#ifdef _WIN32
    (void)pid; (void)wanted; (void)nwanted; (void)out; (void)outcap;
    return -1;
#else
    if (!out || outcap <= 1) return -1;
    out[0] = '\0';

    char dir[64];
    snprintf(dir, sizeof dir, "/proc/%d/fd", pid);
    DIR *d = opendir(dir);
    if (!d) return -1;

    int used = 0, found = 0;
    struct dirent *de;
    /* Sized for the longest real entry ("/proc/" + pid + "/fd/" + name) with
     * room to spare: a truncated path would readlink some OTHER descriptor
     * and attribute the socket to the wrong fd. */
    char link[320], target[128];

    while ((de = readdir(d))) {
        if (de->d_name[0] == '.') continue;
        snprintf(link, sizeof link, "/proc/%d/fd/%s", pid, de->d_name);
        ssize_t n = readlink(link, target, sizeof target - 1);
        if (n <= 0) continue;              /* raced with close(), or denied */
        target[n] = '\0';
        /* Only "socket:[N]" is of interest; pipes and files share the shape
         * but not the prefix, so this rejects the bulk in one compare. */
        if (strncmp(target, "socket:[", 8) != 0) continue;
        long ino = strtol(target + 8, NULL, 10);
        if (ino <= 0) continue;
        if (!inode_wanted(wanted, nwanted, ino)) continue;

        char line[32];
        int len = snprintf(line, sizeof line, "%ld\n", ino);
        if (used + len + 1 > outcap) break;
        memcpy(out + used, line, (size_t)len);
        used += len;
        found++;
    }
    out[used] = '\0';
    closedir(d);
    return found;
#endif
}
