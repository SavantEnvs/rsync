/* Per-exec scratch destination for the rsync_server_recv target.
 *
 * When the last argument is exactly "mayhem-scratch/", the process creates a fresh private directory under
 * $TMPDIR, fills it with a copy of the read-only basis tree (mayhem/rsync_server_recv/basis, found next to
 * the executable), makes it the cwd so the relative destination resolves inside it, and removes it again on
 * exit or on a sanitizer death. A delta seed finds the basis files it was recorded against, and each input
 * starts from the same destination state: its writes never reach another input or another worker.
 * Linked into rsync-afl only; any other invocation is untouched. */
#define _GNU_SOURCE
#include <dirent.h>
#include <fcntl.h>
#include <ftw.h>
#include <libgen.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define SENTINEL "mayhem-scratch/"
#define BASIS_REL "/mayhem/rsync_server_recv/basis"

static char scratch[4096];
static pid_t owner;

__attribute__((weak)) void __sanitizer_set_death_callback(void (*cb)(void));

static int rm_entry(const char *path, const struct stat *sb, int type, struct FTW *ftw)
{
	(void)sb; (void)type; (void)ftw;
	remove(path);
	return 0;
}

static void cleanup(void)
{
	if (!scratch[0] || getpid() != owner)
		return;
	if (chdir("/") == 0)
		nftw(scratch, rm_entry, 16, FTW_DEPTH | FTW_PHYS);
	scratch[0] = '\0';
}

static void copy_basis(const char *basis)
{
	DIR *d = opendir(basis);
	struct dirent *de;
	char src[4096], buf[8192];

	if (!d)
		return;
	while ((de = readdir(d))) {
		struct stat st;
		int in, out;
		ssize_t n;

		if (snprintf(src, sizeof src, "%s/%s", basis, de->d_name) >= (int)sizeof src
		    || stat(src, &st) != 0 || !S_ISREG(st.st_mode))
			continue;
		if ((in = open(src, O_RDONLY)) < 0)
			continue;
		if ((out = open(de->d_name, O_WRONLY | O_CREAT | O_EXCL, st.st_mode & 0777)) >= 0) {
			while ((n = read(in, buf, sizeof buf)) > 0 && write(out, buf, n) == n)
				;
			close(out);
			utimensat(AT_FDCWD, de->d_name, (struct timespec[2]){st.st_mtim, st.st_mtim}, 0);
		}
		close(in);
	}
	closedir(d);
}

__attribute__((constructor)) static void recv_scratch_init(int argc, char **argv, char **envp)
{
	const char *base;
	char exe[4096], basis[4096];
	ssize_t len;

	(void)envp;
	if (argc < 2 || strcmp(argv[argc - 1], SENTINEL) != 0)
		return;
	base = getenv("TMPDIR");
	if (!base || !*base)
		base = "/tmp";
	if (snprintf(scratch, sizeof scratch, "%s/rsync-recv-XXXXXX", base) >= (int)sizeof scratch
	    || !mkdtemp(scratch) || chdir(scratch) != 0) {
		scratch[0] = '\0';
		return;
	}
	owner = getpid();
	atexit(cleanup);
	if (__sanitizer_set_death_callback)
		__sanitizer_set_death_callback(cleanup);

	len = readlink("/proc/self/exe", exe, sizeof exe - 1);
	if (len > 0) {
		exe[len] = '\0';
		if (snprintf(basis, sizeof basis, "%s" BASIS_REL, dirname(exe)) < (int)sizeof basis) {
			mkdir("mayhem-scratch", 0777);
			if (chdir("mayhem-scratch") == 0) {
				copy_basis(basis);
				chdir("..");
			}
		}
	}
}
