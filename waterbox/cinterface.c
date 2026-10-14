/* cinterface.c - VICE's Commodore 64 as a Chimera core: the functions
 * Chimera calls.
 *
 * vice-libretro is a libretro core: a program around it calls its retro_*
 * functions and answers its questions through callbacks. This file is that
 * program, inside the sandbox. It answers the questions from the project
 * (its settings and its files), hands the picture and the sound out, and
 * gives the C64 the controls Chimera sets for each frame: the joysticks into
 * the control ports and the keys into the keyboard matrix, directly (patch
 * 0001 makes upstream's input mapper stand aside).
 *
 * SPDX-License-Identifier: MIT
 */
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include <emulibc.h>
#include <waterbox_settings.h>
#include <waterbox_slots.h>

#include "libretro.h"

/* The three of VICE's functions the controls use. They are declared here
 * rather than taken from VICE's headers: those include upstream's
 * sysconfig.h, which, for a libretro build, turns the C library's file
 * functions into libretro's own and makes stderr 0. */
void joystick_set_value_absolute(unsigned int joyport, uint16_t value);   /* joyport/joystick.h */
void keyboard_set_keyarr(int row, int col, int value);                    /* keyboard.h */
void machine_set_restore_key(int v);                                      /* machine.h */

/* ---- what went wrong, for Chimera to show -------------------------------- */
static char g_loadError[512];

/* ---- the emulator's options ------------------------------------------------
 * vice-libretro declares its options (key, values, default) when it is given
 * its environment. A project's setting with the option's name less "vice_"
 * sets it; any other option keeps upstream's default, which is the first
 * value when the option names none (libretro's rule). A few are fixed here
 * (kForced): what would put the host's state, the computer's clock or
 * pictures of upstream's own menus into a run. */
#define MAX_OPTIONS 512
static struct { const char *key; const char *def; char value[128]; } g_options[MAX_OPTIONS];
static int g_optionCount;

static const struct { const char *key, *value; } kForced[] = {
	{ "vice_autoloadwarp", "disabled" },          /* warp skips pictures to load quicker */
	{ "vice_warp_boost", "disabled" },
	{ "vice_statusbar_messages", "disabled" },
	{ "vice_statusbar_startup", "disabled" },     /* the status bar is drawn into the picture */
	{ "vice_read_vicerc", "disabled" },           /* a configuration file of the host's */
	{ "vice_work_disk", "disabled" },
	{ "vice_physical_keyboard_pass_through", "disabled" },
	{ "vice_datasette_hotkeys", "disabled" },
	{ "vice_turbo_fire", "disabled" },
	{ "vice_printer", "disabled" },
};

static void take_option(const char *key, const char *def)
{
	if (!key || g_optionCount >= MAX_OPTIONS) return;
	for (int i = 0; i < g_optionCount; i++)
		if (!strcmp(g_options[i].key, key)) return;
	g_options[g_optionCount].key = key;
	g_options[g_optionCount].def = def ? def : "";
	g_options[g_optionCount].value[0] = '\0';
	const char *name = !strncmp(key, "vice_", 5) ? key + 5 : key;
	if (wbx_setting_str(name, g_options[g_optionCount].value, sizeof g_options[g_optionCount].value) <= 0)
		snprintf(g_options[g_optionCount].value, sizeof g_options[g_optionCount].value, "%s", g_options[g_optionCount].def);
	for (size_t f = 0; f < sizeof kForced / sizeof kForced[0]; f++)
		if (!strcmp(kForced[f].key, key))
			snprintf(g_options[g_optionCount].value, sizeof g_options[g_optionCount].value, "%s", kForced[f].value);
	g_optionCount++;
}

static const char *option_value(const char *key)
{
	for (int i = 0; i < g_optionCount; i++)
		if (!strcmp(g_options[i].key, key)) return g_options[i].value;
	return NULL;
}

/* ---- the picture -------------------------------------------------------- */
#define MAX_W 1024
#define MAX_H 640
ECL_INVISIBLE static uint32_t g_picture[MAX_W * MAX_H];
static int g_width = 384, g_height = 272;
static int g_render = 1;

/* ---- the sound ---------------------------------------------------------- */
#define MAX_SAMPLES 4096
ECL_INVISIBLE static int16_t g_audio[MAX_SAMPLES * 2];
static int g_audioFrames;

/* ---- the controls -------------------------------------------------------
 * Two joysticks and the keyboard. P1's joystick is in control port 2 by
 * default, where most games read the joystick; the setting P1 Port moves it
 * to port 1, and P2's to the other. The keyboard is the C64's own 66 keys,
 * each set in the keyboard matrix at its row and column (VICE's numbering,
 * the C64's: row is the CIA port A bit that selects it); RESTORE is not in
 * the matrix but on the NMI line. */
enum {
	kP1Up, kP1Down, kP1Left, kP1Right, kP1Fire,
	kP2Up, kP2Down, kP2Left, kP2Right, kP2Fire,
	kFirstKey
};
static const struct { const char *name; int row, col; } kKeys[] = {
	{ "Del", 0, 0 }, { "Return", 0, 1 }, { "Cursor Right", 0, 2 }, { "F7", 0, 3 },
	{ "F1", 0, 4 }, { "F3", 0, 5 }, { "F5", 0, 6 }, { "Cursor Down", 0, 7 },
	{ "3", 1, 0 }, { "W", 1, 1 }, { "A", 1, 2 }, { "4", 1, 3 }, { "Z", 1, 4 }, { "S", 1, 5 }, { "E", 1, 6 }, { "Left Shift", 1, 7 },
	{ "5", 2, 0 }, { "R", 2, 1 }, { "D", 2, 2 }, { "6", 2, 3 }, { "C", 2, 4 }, { "F", 2, 5 }, { "T", 2, 6 }, { "X", 2, 7 },
	{ "7", 3, 0 }, { "Y", 3, 1 }, { "G", 3, 2 }, { "8", 3, 3 }, { "B", 3, 4 }, { "H", 3, 5 }, { "U", 3, 6 }, { "V", 3, 7 },
	{ "9", 4, 0 }, { "I", 4, 1 }, { "J", 4, 2 }, { "0", 4, 3 }, { "M", 4, 4 }, { "K", 4, 5 }, { "O", 4, 6 }, { "N", 4, 7 },
	{ "+", 5, 0 }, { "P", 5, 1 }, { "L", 5, 2 }, { "-", 5, 3 }, { ".", 5, 4 }, { ":", 5, 5 }, { "@", 5, 6 }, { ",", 5, 7 },
	{ "Pound", 6, 0 }, { "*", 6, 1 }, { ";", 6, 2 }, { "Home", 6, 3 }, { "Right Shift", 6, 4 }, { "=", 6, 5 }, { "Up Arrow", 6, 6 }, { "/", 6, 7 },
	{ "1", 7, 0 }, { "Left Arrow", 7, 1 }, { "Ctrl", 7, 2 }, { "2", 7, 3 }, { "Space", 7, 4 }, { "C=", 7, 5 }, { "Q", 7, 6 }, { "Run/Stop", 7, 7 },
	{ "Restore", -1, -1 },
};
#define KEY_COUNT ((int)(sizeof kKeys / sizeof kKeys[0]))
#define BUTTON_COUNT (kFirstKey + KEY_COUNT)
static const char *const kPortButtonNames[kFirstKey] = {
	"P1 Up", "P1 Down", "P1 Left", "P1 Right", "P1 Fire",
	"P2 Up", "P2 Down", "P2 Left", "P2 Right", "P2 Fire",
};
static char g_keyNames[KEY_COUNT][24];
static int g_held[BUTTON_COUNT], g_was[BUTTON_COUNT];
static int g_inputRead;
extern int chimera_input_reads;   /* c64cia1.c (patch 0002) */
int chimera_input_reads;

static int g_p1Port = 2;   /* the control port P1's joystick is in */

static uint16_t joystick_bits(int up)
{
	/* VICE's joystick value: bit 0 up, 1 down, 2 left, 3 right, 4 fire */
	return (uint16_t)((g_held[up] ? 1 : 0) | (g_held[up + 1] ? 2 : 0) | (g_held[up + 2] ? 4 : 0)
		| (g_held[up + 3] ? 8 : 0) | (g_held[up + 4] ? 16 : 0));
}

static void give_controls(void)
{
	/* joystick_set_value_absolute counts the control ports from 0 */
	joystick_set_value_absolute(g_p1Port - 1, joystick_bits(kP1Up));
	joystick_set_value_absolute(2 - g_p1Port, joystick_bits(kP2Up));
	for (int k = 0; k < KEY_COUNT; k++)
	{
		int now = g_held[kFirstKey + k], was = g_was[kFirstKey + k];
		if (now == was) continue;
		if (kKeys[k].row < 0)
			machine_set_restore_key(now);
		else
			keyboard_set_keyarr(kKeys[k].row, kKeys[k].col, now);
	}
	memcpy(g_was, g_held, sizeof g_was);
}

/* ---- the clock ----------------------------------------------------------
 * VICE seeds its random numbers (lib.c: the power-on pattern of the RAM, the
 * random wait before autostart) from time(NULL) as it starts, and reads the
 * date for the clocks of the cartridges that have one. The time it is given
 * is the project's Starting Clock plus the time the machine has run, counted
 * in frames: the same in every run and in every build. These definitions
 * take the place of the C library's; localtime() is UTC, as the sandbox's C
 * library has it. */
#include <sys/time.h>
#include <time.h>
static int64_t g_startTime = 946684800;   /* the first of January 2000 */
static uint64_t g_frameCount;
static double g_fps = 50.0;

static int64_t emulated_usec(void)
{
	return (int64_t)((double)g_frameCount * 1000000.0 / g_fps);
}
time_t time(time_t *t)
{
	time_t v = (time_t)(g_startTime + emulated_usec() / 1000000);
	if (t) *t = v;
	return v;
}
int gettimeofday(struct timeval *restrict tv, void *restrict tz)
{
	(void)tz;
	int64_t us = emulated_usec();
	if (tv)
	{
		tv->tv_sec = (time_t)(g_startTime + us / 1000000);
		tv->tv_usec = (suseconds_t)(us % 1000000);
	}
	return 0;
}
int clock_gettime(clockid_t id, struct timespec *ts)
{
	(void)id;
	int64_t us = emulated_usec();
	ts->tv_sec = (time_t)(g_startTime + us / 1000000);
	ts->tv_nsec = (long)(us % 1000000) * 1000;
	return 0;
}
struct tm *localtime(const time_t *t) { return gmtime(t); }
struct tm *localtime_r(const time_t *restrict t, struct tm *restrict out) { return gmtime_r(t, out); }

/* rand() is the C library's own in each build (glibc's in the native one,
 * musl's in the sandbox), and VICE seeds it beside its own generator: one
 * definition, musl's, for both. */
static uint64_t g_randSeed;
void srand(unsigned s) { g_randSeed = s - 1; }
int rand(void)
{
	g_randSeed = 6364136223846793005ULL * g_randSeed + 1;
	return (int)(g_randSeed >> 33);
}

/* ---- the callbacks vice-libretro calls ----------------------------------- */
static void chimera_log(enum retro_log_level level, const char *fmt, ...)
{
	static int all = -1;
	if (all < 0) all = getenv("CHIMERA_VICE_LOG") != NULL;
	if (level < RETRO_LOG_WARN && !all) return;
	va_list ap;
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
}

int chimera_vfs_answer(struct retro_vfs_interface_info *info);
int chimera_vfs_changed(int i, const char **name, const uint8_t **data, int64_t *size);

static bool environment(unsigned cmd, void *data)
{
	switch (cmd)
	{
	case RETRO_ENVIRONMENT_GET_LOG_INTERFACE:
		((struct retro_log_callback *)data)->log = chimera_log;
		return true;
	case RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION:
		*(unsigned *)data = 2;
		return true;
	case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2:
	{
		const struct retro_core_options_v2 *o = data;
		for (const struct retro_core_option_v2_definition *d = o ? o->definitions : NULL; d && d->key; d++)
			take_option(d->key, d->default_value ? d->default_value : d->values[0].value);
		return true;
	}
	case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2_INTL:
	{
		const struct retro_core_options_v2_intl *o = data;
		for (const struct retro_core_option_v2_definition *d = o && o->us ? o->us->definitions : NULL; d && d->key; d++)
			take_option(d->key, d->default_value ? d->default_value : d->values[0].value);
		return true;
	}
	case RETRO_ENVIRONMENT_GET_VARIABLE:
	{
		struct retro_variable *v = data;
		v->value = option_value(v->key);
		return v->value != NULL;
	}
	case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE:
		*(bool *)data = false;
		return true;
	/* The sandbox's files have no folders: a file is found by its bare name,
	 * so the folders upstream asks for are "". */
	case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
	case RETRO_ENVIRONMENT_GET_CONTENT_DIRECTORY:
	case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
		*(const char **)data = "";
		return true;
	/* every file VICE opens is held in memory (chimera-vfs.c) */
	case RETRO_ENVIRONMENT_GET_VFS_INTERFACE:
		return chimera_vfs_answer(data);
	case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT:
		return *(const enum retro_pixel_format *)data == RETRO_PIXEL_FORMAT_XRGB8888;
	case RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO:
		g_fps = ((const struct retro_system_av_info *)data)->timing.fps;
		return true;
	default:
		return false;
	}
}

static void video_refresh(const void *data, unsigned width, unsigned height, size_t pitch)
{
	if (!data || !g_render) return;
	if (width > MAX_W) width = MAX_W;
	if (height > MAX_H) height = MAX_H;
	g_width = (int)width;
	g_height = (int)height;
	for (unsigned y = 0; y < height; y++)
	{
		const uint32_t *src = (const uint32_t *)((const uint8_t *)data + y * pitch);
		uint32_t *dst = g_picture + (size_t)y * width;
		for (unsigned x = 0; x < width; x++)
			dst[x] = src[x] | 0xFF000000u;
	}
}

static void audio_sample(int16_t left, int16_t right)
{
	if (g_audioFrames >= MAX_SAMPLES) return;
	g_audio[g_audioFrames * 2] = left;
	g_audio[g_audioFrames * 2 + 1] = right;
	g_audioFrames++;
}

static size_t audio_batch(const int16_t *data, size_t frames)
{
	size_t n = frames;
	if (n > (size_t)(MAX_SAMPLES - g_audioFrames)) n = (size_t)(MAX_SAMPLES - g_audioFrames);
	memcpy(g_audio + g_audioFrames * 2, data, n * 4);
	g_audioFrames += (int)n;
	return frames;
}

static void input_poll(void) {}

/* The libretro side of the controls is given nothing: they reach VICE
 * directly (give_controls). */
static int16_t input_state(unsigned port, unsigned device, unsigned index, unsigned id)
{
	(void)port; (void)device; (void)index; (void)id;
	return 0;
}

/* ---- the memory --------------------------------------------------------- */
extern uint8_t mem_ram[];
struct memory_area { const char *name; uint8_t *bytes; int64_t size; };
static struct memory_area g_memory[8];
static int g_memoryCount;

/* ---- the game ----------------------------------------------------------- */
static char g_game[256];

/* ---- Chimera's calls ---------------------------------------------------- */
ECL_EXPORT const char *GetLoadError(void) { return g_loadError; }
ECL_EXPORT const char *SuggestSettings(void) { return "{\"values\":{},\"note\":\"\",\"firmware\":[]}"; }
ECL_EXPORT const char *DescribeDips(void) { return ""; }

ECL_EXPORT int Init(void)
{
	g_loadError[0] = '\0';
	if (wbx_slot_count("game") > 0)
		wbx_slot_name("game", 0, g_game, sizeof g_game);
	else
	{
		/* a game opened with no project is mounted under its own name */
		FILE *f = fopen("rom.name", "rb");
		if (f)
		{
			size_t got = fread(g_game, 1, sizeof g_game - 1, f);
			g_game[got] = '\0';
			fclose(f);
		}
	}
	if (!g_game[0])
	{
		snprintf(g_loadError, sizeof g_loadError, "no game was given");
		return 0;
	}
	{
		char v[32];
		if (wbx_setting_str("p1Port", v, sizeof v) > 0) g_p1Port = v[0] == '1' ? 1 : 2;
		if (wbx_setting_str("initialTime", v, sizeof v) > 0) g_startTime = strtoll(v, NULL, 10);
	}
	g_frameCount = 0;
	for (int k = 0; k < KEY_COUNT; k++)
		snprintf(g_keyNames[k], sizeof g_keyNames[k], "Key %s", kKeys[k].name);

	retro_set_environment(environment);
	retro_set_video_refresh(video_refresh);
	retro_set_audio_sample(audio_sample);
	retro_set_audio_sample_batch(audio_batch);
	retro_set_input_poll(input_poll);
	retro_set_input_state(input_state);
	retro_init();

	struct retro_game_info info = { g_game, NULL, 0, NULL };
	if (!retro_load_game(&info))
	{
		snprintf(g_loadError, sizeof g_loadError, "the emulator did not start with %s", g_game);
		return 0;
	}
	if (getenv("CHIMERA_VICE_OPTIONS"))
		for (int i = 0; i < g_optionCount; i++)
			fprintf(stderr, "option %s = %s\n", g_options[i].key, g_options[i].value);
	struct retro_system_av_info av;
	retro_get_system_av_info(&av);
	g_fps = av.timing.fps;

	g_memoryCount = 0;
	g_memory[g_memoryCount++] = (struct memory_area){ "RAM", mem_ram, 65536 };
	return 1;
}

ECL_EXPORT int GetButtonCount(void) { return BUTTON_COUNT; }
ECL_EXPORT const char *GetButtonName(int32_t i)
{
	if (i < 0 || i >= BUTTON_COUNT) return "";
	return i < kFirstKey ? kPortButtonNames[i] : g_keyNames[i - kFirstKey];
}
ECL_EXPORT int IsButtonActive(int32_t i) { return i >= 0 && i < BUTTON_COUNT; }
ECL_EXPORT void SetButton(int32_t i, int32_t state)
{
	if (i >= 0 && i < BUTTON_COUNT) g_held[i] = state != 0;
}

ECL_EXPORT int GetAxisCount(void) { return 0; }
ECL_EXPORT const char *GetAxisName(int32_t i) { (void)i; return ""; }
ECL_EXPORT int IsAxisActive(int32_t i) { (void)i; return 0; }
ECL_EXPORT void SetAxis(int32_t i, int32_t value) { (void)i; (void)value; }

ECL_EXPORT void FrameAdvance(uint64_t packed)
{
	(void)packed;
	g_audioFrames = 0;
	give_controls();
	chimera_input_reads = 0;
	retro_run();
	g_frameCount++;
	g_inputRead = chimera_input_reads > 0;
}

ECL_EXPORT int InputWasRead(void) { return g_inputRead; }
ECL_EXPORT void SetRenderingEnabled(int on) { g_render = on != 0; }

ECL_EXPORT uint32_t *GetVideoBgra(void) { return g_picture; }
ECL_EXPORT int GetVideoWidth(void) { return g_width; }
ECL_EXPORT int GetVideoHeight(void) { return g_height; }
ECL_EXPORT int GetDisplayAspectX(void) { return 4; }
ECL_EXPORT int GetDisplayAspectY(void) { return 3; }
ECL_EXPORT int GetVsyncNumerator(void) { return (int)(g_fps * 1000.0 + 0.5); }
ECL_EXPORT int GetVsyncDenominator(void) { return 1000; }

ECL_EXPORT int16_t *GetAudio(void) { return g_audio; }
ECL_EXPORT int GetAudioSampleCount(void) { return g_audioFrames; }

ECL_EXPORT int GetMemoryDomainCount(void) { return g_memoryCount; }
ECL_EXPORT const char *GetMemoryDomainName(int i) { return i >= 0 && i < g_memoryCount ? g_memory[i].name : ""; }
ECL_EXPORT uint8_t *GetMemoryDomainPtr(int i) { return i >= 0 && i < g_memoryCount ? g_memory[i].bytes : NULL; }
ECL_EXPORT int64_t GetMemoryDomainSize(int i) { return i >= 0 && i < g_memoryCount ? g_memory[i].size : 0; }
ECL_EXPORT int GetMemoryDomainWritable(int i) { return i >= 0 && i < g_memoryCount; }

ECL_EXPORT const int64_t *GetBusRanges(int32_t bus) { (void)bus; return NULL; }
ECL_EXPORT const uint8_t *ReadBus(int32_t bus, int64_t addr, int32_t len) { (void)bus; (void)addr; (void)len; return NULL; }
ECL_EXPORT void PokeBus(int32_t bus, int32_t addr, int32_t value) { (void)bus; (void)addr; (void)value; }

/* Export Save Data: each file the C64 changed (a disk it wrote to), as it
 * is now, under its own name (chimera-vfs.c keeps them in memory) */
static const char *g_saveName[16];
static const uint8_t *g_saveData[16];
static int64_t g_saveSize[16];
static int g_saveCount;
ECL_EXPORT int32_t GetSaveDataFileCount(void)
{
	g_saveCount = 0;
	while (g_saveCount < 16 && chimera_vfs_changed(g_saveCount, &g_saveName[g_saveCount], &g_saveData[g_saveCount], &g_saveSize[g_saveCount]))
		g_saveCount++;
	return g_saveCount;
}
ECL_EXPORT const char *GetSaveDataFileName(int32_t i) { return i >= 0 && i < g_saveCount ? g_saveName[i] : ""; }
ECL_EXPORT int64_t GetSaveDataFileSize(int32_t i) { return i >= 0 && i < g_saveCount ? g_saveSize[i] : 0; }
ECL_EXPORT const uint8_t *GetSaveDataFileBuffer(int32_t i) { return i >= 0 && i < g_saveCount ? g_saveData[i] : NULL; }

