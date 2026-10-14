/* Sandbox-only replacements for C library calls whose system calls miniBox
 * does not have. One static link means defining these here takes the place
 * of the C library's versions. Not compiled into the native reference.
 *
 * VICE asks whether a file is there before it opens it. In a sandbox there are files mounted by name and no folders: a path
 * is "there" when it can be opened, and what it is is what the open file
 * says; anything else is not there. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

/* The C library's fstat() is fstatat() of an empty path on an open file, so
 * this function is asked both things: about an open file (answered by the
 * system call the sandbox does have), and about a name (answered by opening
 * it). */
int fstatat(int dirfd, const char *path, struct stat *st, int flags)
{
	if (path && !*path && (flags & AT_EMPTY_PATH)) {
		if (syscall(SYS_fstat, dirfd, st) != 0) {
			errno = EBADF;
			return -1;
		}
		return 0;
	}
	if (!path || !*path) {
		errno = ENOENT;
		return -1;
	}
	const int fd = open(path, O_RDONLY);
	if (fd < 0) {
		errno = ENOENT;
		return -1;
	}
	const long r = syscall(SYS_fstat, fd, st);
	close(fd);
	if (r != 0) {
		errno = EIO;
		return -1;
	}
	return 0;
}

int stat(const char *path, struct stat *st) { return fstatat(AT_FDCWD, path, st, 0); }
int lstat(const char *path, struct stat *st) { return fstatat(AT_FDCWD, path, st, 0); }

int access(const char *path, int mode)
{
	struct stat st;
	(void)mode;
	return stat(path, &st);
}

/* VICE builds the folders it looks for its files in from the current
 * folder (sysfile.c, archdep_current_dir), and a sandbox has no folders:
 * the current one is ".", which the sandbox's names do not need. (getcwd's
 * system call is not one the sandbox has.) */
char *getcwd(char *buf, size_t size)
{
	if (!buf || size < 2) {
		errno = ERANGE;
		return NULL;
	}
	buf[0] = '.';
	buf[1] = '\0';
	return buf;
}
