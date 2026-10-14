/* chimera-vfs.c - every file VICE opens, held in memory.
 *
 * vice-libretro does all its file work through libretro's file interface,
 * which a frontend may supply (RETRO_ENVIRONMENT_GET_VFS_INTERFACE). This is
 * the core's: a file is read whole from the sandbox's files the first time
 * it is opened and kept in memory; a write changes only that copy, so a
 * project's files are never changed, a disk the C64 writes to is writable
 * (in the sandbox the files themselves cannot be written, and a disk VICE
 * finds read-only it attaches write-protected, which the 1541 can read),
 * both builds see the same, and a savestate, which is all of the machine's
 * memory, holds every file as the machine left it. Export Save Data hands
 * out the files that were changed.
 *
 * SPDX-License-Identifier: MIT
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "libretro.h"

#define MAX_FILES 64

struct memfile {
	char name[256];
	uint8_t *data;
	int64_t size, cap;
	int exists;     /* removed files keep their slot */
	int changed;    /* written since it was read */
};

struct retro_vfs_file_handle {
	struct memfile *f;
	int64_t pos;
	unsigned mode;
	char path[256];
};

static struct memfile g_files[MAX_FILES];
static int g_fileCount;

/* the sandbox's files have no folders: "./x", "././vice/x" and "x" name
 * the same file when the last part is the same */
static const char *base_name(const char *path)
{
	const char *b = strrchr(path, '/');
	return b ? b + 1 : path;
}

static struct memfile *find(const char *path)
{
	const char *name = base_name(path);
	for (int i = 0; i < g_fileCount; i++)
		if (!strcmp(g_files[i].name, name)) return &g_files[i];
	return NULL;
}

static int grow(struct memfile *f, int64_t need)
{
	if (need <= f->cap) return 1;
	int64_t cap = f->cap ? f->cap : 4096;
	while (cap < need) cap *= 2;
	uint8_t *d = realloc(f->data, (size_t)cap);
	if (!d) return 0;
	memset(d + f->cap, 0, (size_t)(cap - f->cap));
	f->data = d;
	f->cap = cap;
	return 1;
}

/* the file as the sandbox has it, read the first time it is asked for */
static struct memfile *load(const char *path)
{
	struct memfile *f = find(path);
	if (f) return f;
	if (g_fileCount >= MAX_FILES) return NULL;
	FILE *h = fopen(base_name(path), "rb");
	if (!h) return NULL;
	f = &g_files[g_fileCount];
	memset(f, 0, sizeof *f);
	snprintf(f->name, sizeof f->name, "%s", base_name(path));
	uint8_t buf[65536];
	size_t n;
	while ((n = fread(buf, 1, sizeof buf, h)) > 0)
	{
		if (!grow(f, f->size + (int64_t)n)) { fclose(h); free(f->data); return NULL; }
		memcpy(f->data + f->size, buf, n);
		f->size += (int64_t)n;
	}
	fclose(h);
	f->exists = 1;
	g_fileCount++;
	return f;
}

static struct memfile *create(const char *path)
{
	struct memfile *f = find(path);
	if (!f)
	{
		if (g_fileCount >= MAX_FILES) return NULL;
		f = &g_files[g_fileCount++];
		memset(f, 0, sizeof *f);
		snprintf(f->name, sizeof f->name, "%s", base_name(path));
	}
	f->exists = 1;
	f->size = 0;
	f->changed = 1;
	return f;
}

static const char *RETRO_CALLCONV vfs_get_path(struct retro_vfs_file_handle *s) { return s ? s->path : NULL; }

static struct retro_vfs_file_handle *RETRO_CALLCONV vfs_open(const char *path, unsigned mode, unsigned hints)
{
	(void)hints;
	if (!path || !*path) return NULL;
	struct memfile *f;
	if ((mode & RETRO_VFS_FILE_ACCESS_WRITE) && !(mode & RETRO_VFS_FILE_ACCESS_UPDATE_EXISTING))
		f = create(path);   /* written from the start: an empty file */
	else
	{
		f = load(path);
		if (f && !f->exists) f = NULL;
		if (!f && (mode & RETRO_VFS_FILE_ACCESS_WRITE)) f = create(path);
	}
	if (!f) return NULL;
	struct retro_vfs_file_handle *s = calloc(1, sizeof *s);
	if (!s) return NULL;
	s->f = f;
	s->mode = mode;
	snprintf(s->path, sizeof s->path, "%s", path);
	return s;
}

static int RETRO_CALLCONV vfs_close(struct retro_vfs_file_handle *s) { free(s); return 0; }
static int64_t RETRO_CALLCONV vfs_size(struct retro_vfs_file_handle *s) { return s ? s->f->size : -1; }
static int64_t RETRO_CALLCONV vfs_tell(struct retro_vfs_file_handle *s) { return s ? s->pos : -1; }

static int64_t RETRO_CALLCONV vfs_truncate(struct retro_vfs_file_handle *s, int64_t length)
{
	if (!s || length < 0 || !(s->mode & RETRO_VFS_FILE_ACCESS_WRITE)) return -1;
	if (!grow(s->f, length)) return -1;
	if (length > s->f->size) memset(s->f->data + s->f->size, 0, (size_t)(length - s->f->size));
	s->f->size = length;
	s->f->changed = 1;
	return 0;
}

static int64_t RETRO_CALLCONV vfs_seek(struct retro_vfs_file_handle *s, int64_t offset, int whence)
{
	if (!s) return -1;
	int64_t base = whence == RETRO_VFS_SEEK_POSITION_START ? 0
		: whence == RETRO_VFS_SEEK_POSITION_CURRENT ? s->pos : s->f->size;
	if (base + offset < 0) return -1;
	s->pos = base + offset;
	return 0;   /* as libretro's own file layer answers: fseek's 0, not the position */
}

static int64_t RETRO_CALLCONV vfs_read(struct retro_vfs_file_handle *s, void *buf, uint64_t len)
{
	if (!s || !(s->mode & RETRO_VFS_FILE_ACCESS_READ)) return -1;
	if (s->pos >= s->f->size) return 0;
	int64_t n = s->f->size - s->pos;
	if ((uint64_t)n > len) n = (int64_t)len;
	memcpy(buf, s->f->data + s->pos, (size_t)n);
	s->pos += n;
	return n;
}

static int64_t RETRO_CALLCONV vfs_write(struct retro_vfs_file_handle *s, const void *buf, uint64_t len)
{
	if (!s || !(s->mode & RETRO_VFS_FILE_ACCESS_WRITE)) return -1;
	if (!grow(s->f, s->pos + (int64_t)len)) return -1;
	if (s->pos > s->f->size) memset(s->f->data + s->f->size, 0, (size_t)(s->pos - s->f->size));
	if (len && memcmp(s->f->data + s->pos, buf, (size_t)len)) s->f->changed = 1;
	memcpy(s->f->data + s->pos, buf, (size_t)len);
	s->pos += (int64_t)len;
	if (s->pos > s->f->size) { s->f->size = s->pos; s->f->changed = 1; }
	return (int64_t)len;
}

static int RETRO_CALLCONV vfs_flush(struct retro_vfs_file_handle *s) { (void)s; return 0; }

static int RETRO_CALLCONV vfs_remove(const char *path)
{
	struct memfile *f = load(path);
	if (!f || !f->exists) return -1;
	f->exists = 0;
	f->size = 0;
	f->changed = 1;
	return 0;
}

static int RETRO_CALLCONV vfs_rename(const char *from, const char *to)
{
	struct memfile *f = load(from);
	if (!f || !f->exists) return -1;
	struct memfile *t = create(to);
	if (!t || !grow(t, f->size)) return -1;
	memcpy(t->data, f->data, (size_t)f->size);
	t->size = f->size;
	f->exists = 0;
	f->size = 0;
	return 0;
}

static struct retro_vfs_interface g_vfs = {
	vfs_get_path, vfs_open, vfs_close, vfs_size, vfs_tell, vfs_seek, vfs_read, vfs_write,
	vfs_flush, vfs_remove, vfs_rename, vfs_truncate,
};

/* RETRO_ENVIRONMENT_GET_VFS_INTERFACE: version 2, which is what upstream asks */
int chimera_vfs_answer(struct retro_vfs_interface_info *info)
{
	if (!info || info->required_interface_version > 2) return 0;
	info->required_interface_version = 2;
	info->iface = &g_vfs;
	return 1;
}

/* Export Save Data: the files that were written to and still exist */
int chimera_vfs_changed(int i, const char **name, const uint8_t **data, int64_t *size)
{
	int k = 0;
	for (int j = 0; j < g_fileCount; j++)
	{
		if (!g_files[j].changed || !g_files[j].exists) continue;
		if (k++ != i) continue;
		*name = g_files[j].name;
		*data = g_files[j].data;
		*size = g_files[j].size;
		return 1;
	}
	return 0;
}
