#define _GNU_SOURCE
#include <caml/mlvalues.h>
#include <caml/unixsupport.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

/* All names below a directory descriptor are single components. No operations on
   records go back through a pathname whose parent could have been replaced. */
static const char *component(value name, const char *op)
{
  caml_unix_check_path(name, op);
  const char *s = String_val(name);
  if (*s == '\0' || strchr(s, '/') || !strcmp(s, ".") || !strcmp(s, "..")) {
    errno = EINVAL;
    caml_uerror(op, name);
  }
  return s;
}

static int check_dir(int fd, int private)
{
  struct stat st;
  if (fstat(fd, &st) == -1) return -1;
  if (S_ISDIR(st.st_mode) &&
      (private
         ? st.st_uid == geteuid() && (st.st_mode & 07777) == 0700
         : (st.st_uid == geteuid() || st.st_uid == 0) &&
           (!(st.st_mode & 0022) || (st.st_uid == 0 && (st.st_mode & S_ISVTX)))))
    return 0;
  errno = EPERM;
  return -1;
}

static int open_dir(int parent, const char *name, int create, int private)
{
  int fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (fd == -1 && errno == ENOENT && create) {
    if (mkdirat(parent, name, 0700) == -1 && errno != EEXIST) return -1;
    fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  }
  if (fd != -1 && check_dir(fd, private) == -1) {
    int saved = errno;
    close(fd);
    errno = saved;
    return -1;
  }
  return fd;
}

CAMLprim value silver_share_open_path(value path, value create, value private)
{
  const char *op = "open safe share directory";
  caml_unix_check_path(path, op);
  if (String_val(path)[0] != '/') {
    errno = EINVAL;
    caml_uerror(op, path);
  }
  char *copy = strdup(String_val(path));
  if (!copy) caml_uerror(op, path);
  char *save;
  char *part = strtok_r(copy, "/", &save);
  int fd = open_dir(AT_FDCWD, "/", 0, !part && Bool_val(private));
  int saved = errno;
  while (fd != -1 && part) {
    char *next = strtok_r(NULL, "/", &save);
    int child = -1;
    if (!strcmp(part, ".") || !strcmp(part, ".."))
      errno = EINVAL;
    else
      child = open_dir(fd, part, Bool_val(create), !next && Bool_val(private));
    saved = errno;
    close(fd);
    fd = child;
    part = next;
  }
  free(copy);
  if (fd == -1) {
    errno = saved;
    caml_uerror(op, path);
  }
  return Val_int(fd);
}

CAMLprim value silver_share_open_dir(value parent, value name, value create,
                                    value private)
{
  const char *op = "open safe share subdirectory";
  const char *s = component(name, op);
  int fd = open_dir(Int_val(parent), s, Bool_val(create), Bool_val(private));
  if (fd == -1) caml_uerror(op, name);
  return Val_int(fd);
}

static int private_file(const struct stat *st)
{
  return S_ISREG(st->st_mode) && st->st_uid == geteuid() &&
         (st->st_mode & 07777) == 0600 && st->st_nlink == 1;
}

static int same_inode(const struct stat *left, const struct stat *right)
{
  return left->st_dev == right->st_dev && left->st_ino == right->st_ino;
}

CAMLprim value silver_share_open_file(value parent, value name, value fresh)
{
  const char *op = "open safe share record";
  const char *s = component(name, op);
  int flags = Bool_val(fresh) ? O_RDWR | O_CREAT | O_EXCL : O_RDONLY;
  int fd = openat(Int_val(parent), s,
                  flags | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0600);
  if (fd == -1) caml_uerror(op, name);
  struct stat st;
  int status = fstat(fd, &st);
  if (status == -1 || !private_file(&st)) {
    int saved = status == -1 ? errno : EPERM;
    struct stat entry;
    if (Bool_val(fresh) && status == 0 &&
        fstatat(Int_val(parent), s, &entry, AT_SYMLINK_NOFOLLOW) == 0 &&
        same_inode(&st, &entry))
      unlinkat(Int_val(parent), s, 0);
    close(fd);
    errno = saved;
    caml_uerror(op, name);
  }
  return Val_int(fd);
}

static int read_entry(int parent, const char *name, int fd, struct stat *entry)
{
  struct stat open_file;
  if (fstat(fd, &open_file) == -1) return -1;
  if (fstatat(parent, name, entry, AT_SYMLINK_NOFOLLOW) == -1)
    return errno == ENOENT ? 0 : -1;
  return same_inode(&open_file, entry);
}

CAMLprim value silver_share_same_entry(value parent, value name, value fd)
{
  const char *op = "check share entry identity";
  const char *s = component(name, op);
  struct stat entry;
  int same = read_entry(Int_val(parent), s, Int_val(fd), &entry);
  if (same == -1) caml_uerror(op, name);
  return Val_bool(same && private_file(&entry));
}

CAMLprim value silver_share_same_dir(value a, value b)
{
  struct stat left, right;
  if (fstat(Int_val(a), &left) == -1 || fstat(Int_val(b), &right) == -1)
    caml_uerror("check share directory identity", Nothing);
  return Val_bool(same_inode(&left, &right));
}

CAMLprim value silver_share_try_flock(value fd, value exclusive)
{
  int result;
  do {
    result = flock(Int_val(fd), LOCK_NB | (Bool_val(exclusive) ? LOCK_EX : LOCK_SH));
  } while (result == -1 && errno == EINTR);
  if (result == 0) return Val_true;
  if (errno == EWOULDBLOCK || errno == EAGAIN) return Val_false;
  caml_uerror("flock share record", Nothing);
}

CAMLprim value silver_share_rename_fresh(value parent, value old_name, value new_name)
{
  const char *op = "publish share record";
  const char *old = component(old_name, op), *new = component(new_name, op);
  int fd = Int_val(parent);
#if defined(__linux__)
  int status = renameat2(fd, old, fd, new, RENAME_NOREPLACE);
#elif defined(__APPLE__)
  int status = renameatx_np(fd, old, fd, new, RENAME_EXCL);
#else
  int status = -1;
  errno = ENOTSUP;
#endif
  if (status == -1) caml_uerror(op, new_name);
  return Val_unit;
}

CAMLprim value silver_share_unlink_same(value parent, value name, value fd)
{
  const char *op = "unlink share record";
  const char *s = component(name, op);
  struct stat entry;
  int same = read_entry(Int_val(parent), s, Int_val(fd), &entry);
  if (same == -1 ||
      (same && unlinkat(Int_val(parent), s, 0) == -1 && errno != ENOENT))
    caml_uerror(op, name);
  return Val_unit;
}
