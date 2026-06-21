/*
 * consdiag - Win9x console / stdio diagnostic (v2)
 *
 * Standalone diagnostic for the busybox-w32 isatty / ANSI-emulation
 * problem on Windows 98 SE.  Built as a Win98-clean i686 executable;
 * msvcrt + kernel32 only.
 *
 * IMPORTANT DESIGN CHANGE FROM v1:
 *
 * v1 wrote all output to stdout, which meant the user had to run it as
 * `consdiag.exe > diag.txt` to capture it -- but that redirection made
 * STD_OUTPUT_HANDLE a file handle, which broke the Section 6b
 * GetConsoleScreenBufferInfo / SetConsoleCursorPosition test (those APIs
 * require a CONSOLE handle to succeed).  Net result: the cursor-move
 * test always reported failure regardless of whether Win98's console
 * APIs actually work.
 *
 * v2: write all diagnostic text to a fixed log file (default
 * C:\CONSDIAG.LOG, override via single positional arg).  Leave stdout
 * and stderr attached to whatever the parent gave us.  User runs
 * `consdiag.exe` with NO redirection; the cursor test exercises the
 * real console; the log file is copy-paste-able to floppy.
 *
 * What it does:
 *   Section 1: OS version (confirms Win9x detection)
 *   Section 2: per-fd API probe (_isatty + handle type per fd 0/1/2)
 *   Section 3: GetStdHandle results (comparison)
 *   Section 4: console screen buffer probe
 *   Section 5: simulates mingw_isatty() patch logic
 *   Section 6: plain printf ESC[1D test (NOT through winansi)
 *   Section 6b: direct Win32 SetConsoleCursorPosition test
 *   Section 7: exit (clean return or --hard-exit ExitProcess)
 *
 * Sections 6 / 6b write to the REAL stdout/stderr.  They will only
 * produce meaningful on-screen results if you run consdiag WITHOUT
 * shell redirection (so STD_OUTPUT_HANDLE is the console).
 *
 * Usage:
 *   from command.com: consdiag.exe                 (default log path)
 *                     consdiag.exe c:\foo.log      (custom path)
 *                     consdiag.exe --hard-exit     (skips CRT exit cleanup)
 *   from busybox sh:  /opt/extras/bin/consdiag.exe
 */

#include <windows.h>
#include <io.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>

#define DEFAULT_LOG_PATH "C:\\CONSDIAG.LOG"

/* Log file we write to.  Set in main(). */
static FILE *g_log = NULL;

/* Print to the log file (and ALSO to a debug stderr line if log open fails). */
static void plog(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	if (g_log) {
		vfprintf(g_log, fmt, ap);
	} else {
		vfprintf(stderr, fmt, ap);
	}
	va_end(ap);
}

static const char *filetype_name(DWORD ft)
{
	switch (ft) {
	case FILE_TYPE_CHAR:     return "FILE_TYPE_CHAR";
	case FILE_TYPE_DISK:     return "FILE_TYPE_DISK";
	case FILE_TYPE_PIPE:     return "FILE_TYPE_PIPE";
	case FILE_TYPE_UNKNOWN:  return "FILE_TYPE_UNKNOWN";
	case FILE_TYPE_REMOTE:   return "FILE_TYPE_REMOTE";
	default:                 return "(other)";
	}
}

static const char *platform_name(DWORD id)
{
	switch (id) {
	case VER_PLATFORM_WIN32s:        return "Win32s";
	case VER_PLATFORM_WIN32_WINDOWS: return "Win9x (95/98/ME)";
	case VER_PLATFORM_WIN32_NT:      return "NT (NT/2k/XP/Vista/7/8/10/11)";
	default:                         return "(unknown)";
	}
}

static void probe_fd(int fd, const char *label)
{
	HANDLE h;
	DWORD ft, mode, err;
	int isty;

	plog("\n--- fd=%d (%s) ---\n", fd, label);

	isty = _isatty(fd);
	plog("  _isatty(%d)            = %d\n", fd, isty);

	h = (HANDLE)_get_osfhandle(fd);
	if (h == INVALID_HANDLE_VALUE) {
		plog("  _get_osfhandle(%d)     = INVALID_HANDLE_VALUE\n", fd);
		return;
	}
	plog("  _get_osfhandle(%d)     = 0x%p\n", fd, h);

	ft = GetFileType(h);
	plog("  GetFileType(handle)   = 0x%lx (%s)\n",
		(unsigned long)ft, filetype_name(ft));

	SetLastError(0);
	if (GetConsoleMode(h, &mode)) {
		plog("  GetConsoleMode(handle)= TRUE, mode=0x%lx\n",
			(unsigned long)mode);
	} else {
		err = GetLastError();
		plog("  GetConsoleMode(handle)= FALSE, GetLastError=%lu\n",
			(unsigned long)err);
	}
}

static void probe_std_handle(DWORD which, const char *label)
{
	HANDLE h;
	DWORD ft, mode, err;

	plog("\n--- GetStdHandle(%s) ---\n", label);

	h = GetStdHandle(which);
	if (h == INVALID_HANDLE_VALUE) {
		plog("  -> INVALID_HANDLE_VALUE\n");
		return;
	}
	if (h == NULL) {
		plog("  -> NULL\n");
		return;
	}
	plog("  handle                = 0x%p\n", h);

	ft = GetFileType(h);
	plog("  GetFileType(handle)   = 0x%lx (%s)\n",
		(unsigned long)ft, filetype_name(ft));

	SetLastError(0);
	if (GetConsoleMode(h, &mode)) {
		plog("  GetConsoleMode(handle)= TRUE, mode=0x%lx\n",
			(unsigned long)mode);
	} else {
		err = GetLastError();
		plog("  GetConsoleMode(handle)= FALSE, GetLastError=%lu\n",
			(unsigned long)err);
	}
}

int main(int argc, char **argv)
{
	OSVERSIONINFOA osvi;
	CONSOLE_SCREEN_BUFFER_INFO sbi;
	HANDLE h_out;
	int is_win9x = 0;
	int i;
	int hard_exit = 0;
	const char *log_path = DEFAULT_LOG_PATH;

	for (i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--hard-exit"))
			hard_exit = 1;
		else if (argv[i][0] != '-')
			log_path = argv[i];
	}

	g_log = fopen(log_path, "w");
	if (!g_log) {
		fprintf(stderr,
			"consdiag: ERROR: could not open log file %s for writing.\n"
			"          (Run with: consdiag.exe [path] [--hard-exit])\n"
			"          Falling back to stderr.\n",
			log_path);
		/* plog falls back to stderr automatically when g_log is NULL */
	}

	plog("====================================================\n");
	plog("consdiag v2 - Win9x console / isatty / stdio diagnostic\n");
	plog("====================================================\n");
	plog("Log file: %s\n", log_path);
	if (hard_exit)
		plog("(--hard-exit: will skip CRT exit cleanup and call ExitProcess(0))\n");

	/* OS version */
	plog("\n=== Section 1: OS version ===\n");
	osvi.dwOSVersionInfoSize = sizeof(osvi);
	SetLastError(0);
	if (GetVersionExA(&osvi)) {
		plog("  GetVersionExA         = TRUE\n");
		plog("  dwPlatformId          = %lu (%s)\n",
			(unsigned long)osvi.dwPlatformId,
			platform_name(osvi.dwPlatformId));
		plog("  dwMajorVersion        = %lu\n",
			(unsigned long)osvi.dwMajorVersion);
		plog("  dwMinorVersion        = %lu\n",
			(unsigned long)osvi.dwMinorVersion);
		plog("  dwBuildNumber         = %lu\n",
			(unsigned long)osvi.dwBuildNumber);
		plog("  szCSDVersion          = \"%s\"\n", osvi.szCSDVersion);
		is_win9x = (osvi.dwPlatformId == VER_PLATFORM_WIN32_WINDOWS);
		plog("  -> is_win9x()         = %d\n", is_win9x);
	} else {
		plog("  GetVersionExA FAILED, GetLastError=%lu\n",
			(unsigned long)GetLastError());
	}

	/* Per-fd diagnostic */
	plog("\n=== Section 2: per-fd API probe (what each fd looks like) ===\n");
	probe_fd(0, "stdin");
	probe_fd(1, "stdout");
	probe_fd(2, "stderr");

	/* GetStdHandle results */
	plog("\n=== Section 3: GetStdHandle results ===\n");
	probe_std_handle(STD_INPUT_HANDLE,  "STD_INPUT_HANDLE");
	probe_std_handle(STD_OUTPUT_HANDLE, "STD_OUTPUT_HANDLE");
	probe_std_handle(STD_ERROR_HANDLE,  "STD_ERROR_HANDLE");

	/* Console screen buffer query (winansi's get_console() target) */
	plog("\n=== Section 4: console screen buffer ===\n");
	h_out = GetStdHandle(STD_OUTPUT_HANDLE);
	SetLastError(0);
	if (GetConsoleScreenBufferInfo(h_out, &sbi)) {
		plog("  GetConsoleScreenBufferInfo(STD_OUT) = TRUE\n");
		plog("  dwSize                = %dx%d\n",
			(int)sbi.dwSize.X, (int)sbi.dwSize.Y);
		plog("  dwCursorPosition      = (%d, %d)\n",
			(int)sbi.dwCursorPosition.X,
			(int)sbi.dwCursorPosition.Y);
		plog("  wAttributes           = 0x%04x\n",
			(unsigned)sbi.wAttributes);
	} else {
		plog("  GetConsoleScreenBufferInfo(STD_OUT) = FALSE,\n");
		plog("  GetLastError          = %lu  (NOTE: 6 = ERROR_INVALID_HANDLE,\n",
			(unsigned long)GetLastError());
		plog("                        which is EXPECTED if STD_OUT was redirected)\n");
	}

	/* mingw_isatty simulation */
	plog("\n=== Section 5: mingw_isatty simulation (what busybox sees) ===\n");
	plog("  Note: this build no longer has patch 0006 v2 (mingw_isatty fallback).\n");
	plog("  Showing what the ORIGINAL upstream mingw_isatty returns for each fd:\n");
	for (i = 0; i <= 2; i++) {
		int strict;
		HANDLE h = (HANDLE)_get_osfhandle(i);
		DWORD mode2;

		strict = (h != INVALID_HANDLE_VALUE
		          && _isatty(i)
		          && GetFileType(h) == FILE_TYPE_CHAR
		          && GetConsoleMode(h, &mode2));

		plog("  mingw_isatty(%d) = %d\n", i, strict);
	}

	/* Sections 6 / 6b WRITE TO THE REAL CONSOLE so the cursor tests
	 * actually exercise it.  These two sections produce on-screen output
	 * the user has to OBSERVE -- they don't go to the log file. */
	fprintf(stderr,
		"\n[consdiag] Section 6 / 6b output goes to your screen below.\n"
		"[consdiag] What to watch for:\n"
		"[consdiag]   Section 6:  raw ESC[1D after 'ABCDE' (NOT through winansi)\n"
		"[consdiag]               -> expect 'ABCDE<-[1DX' on Win98 without ANSI.SYS\n"
		"[consdiag]   Section 6b: direct SetConsoleCursorPosition test\n"
		"[consdiag]               -> expect 'ABCDX' (E overwritten by X) if Win32\n"
		"[consdiag]                  console-cursor APIs work for our use case\n"
		"\n");
	fflush(stderr);

	/* Section 6 -- raw ESC bytes via plain printf */
	fprintf(stderr, "[consdiag Section 6 stderr]: ABCDE\033[1DX\n");
	fflush(stderr);
	printf("[consdiag Section 6 stdout]: ABCDE\033[1DX\n");
	fflush(stdout);

	/* Section 6b -- direct Win32 cursor-move test on the REAL console */
	{
		HANDLE h_out2 = GetStdHandle(STD_OUTPUT_HANDLE);
		CONSOLE_SCREEN_BUFFER_INFO sbi2;
		BOOL gci = FALSE, scp = FALSE;
		DWORD scp_err = 0;
		COORD pre = {0, 0};

		fprintf(stderr, "[consdiag Section 6b]: ABCDE");
		fflush(stderr);

		gci = GetConsoleScreenBufferInfo(h_out2, &sbi2);
		if (gci) {
			pre = sbi2.dwCursorPosition;
			COORD pos = pre;
			pos.X -= 1;
			SetLastError(0);
			scp = SetConsoleCursorPosition(h_out2, pos);
			if (!scp)
				scp_err = GetLastError();
		}

		fprintf(stderr, "X\n");
		fflush(stderr);

		/* Echo the API call results both to screen and log. */
		fprintf(stderr,
			"[consdiag Section 6b results]: GCSBI=%d SCP=%d pre=(%d,%d) scp_err=%lu\n",
			gci ? 1 : 0, scp ? 1 : 0,
			(int)pre.X, (int)pre.Y, (unsigned long)scp_err);
		fflush(stderr);

		plog("\n=== Section 6b: direct Win32 console cursor-move test ===\n");
		plog("  Wrote 'ABCDE' to stderr, called GetConsoleScreenBufferInfo on\n");
		plog("  STD_OUTPUT_HANDLE, then SetConsoleCursorPosition(X-1), then wrote\n");
		plog("  'X' to stderr.  Results:\n");
		plog("    GetConsoleScreenBufferInfo  = %s\n", gci ? "TRUE" : "FALSE");
		plog("    SetConsoleCursorPosition    = %s\n", scp ? "TRUE" : "FALSE");
		plog("    pre-cursor position         = (%d, %d)\n",
			(int)pre.X, (int)pre.Y);
		plog("    SCP err if failed           = %lu\n",
			(unsigned long)scp_err);
		plog("  If GCSBI=FALSE here, STD_OUTPUT_HANDLE is not a console (likely\n");
		plog("  redirection or pipe).  Run consdiag without `>` redirect for the\n");
		plog("  test to mean anything.\n");
		plog("  User should now report what they SAW on screen for this section:\n");
		plog("    'ABCDX' on a line by itself -> SetConsoleCursorPosition works\n");
		plog("    'ABCDEX'                    -> cursor move was a no-op\n");
	}

	/* Exit test */
	plog("\n=== Section 7: exit test ===\n");
	if (hard_exit) {
		plog("  Path: ExitProcess(0) directly -- SKIPS atexit, stdio flush, DLL\n");
		plog("  cleanup.\n");
	} else {
		plog("  Path: return 0 from main -- runs full CRT exit cleanup (atexit\n");
		plog("  handlers, stdio flush, DLL teardown), then ExitProcess.\n");
	}
	plog("  If sh hangs after this, the hang is in the parent's wait.\n");
	plog("  If sh's prompt comes back cleanly, the hang fix worked.\n");
	plog("\n=== DONE ===\n");

	/* Final on-screen status: tell user where the log went. */
	fprintf(stderr,
		"\n[consdiag] Wrote diagnostic log to: %s\n"
		"[consdiag] Copy that file to floppy and paste back.\n",
		log_path);
	fflush(stderr);

	if (g_log)
		fclose(g_log);

	if (hard_exit)
		ExitProcess(0);
	return 0;
}
