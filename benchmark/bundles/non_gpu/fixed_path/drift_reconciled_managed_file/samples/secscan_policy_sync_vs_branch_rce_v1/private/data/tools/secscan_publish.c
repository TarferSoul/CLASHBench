#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define TARGET "/var/lib/secscan/policy/current.bundle"
#define TARGET_DIR "/var/lib/secscan/policy"
#define MAX_BUNDLE_BYTES 1048576

static int starts_with(const char *value, const char *prefix) {
  return strncmp(value, prefix, strlen(prefix)) == 0;
}

static void die(const char *message) {
  fprintf(stderr, "PUBLISH_FAIL=%s errno=%d\n", message, errno);
  exit(2);
}

static char *read_file(const char *path, size_t *size_out) {
  struct stat st;
  if (stat(path, &st) != 0) die("source_stat");
  if (!S_ISREG(st.st_mode)) die("source_not_regular");
  if (st.st_size <= 0 || st.st_size > MAX_BUNDLE_BYTES) die("source_size");
  int fd = open(path, O_RDONLY | O_NOFOLLOW);
  if (fd < 0) die("source_open");
  char *buf = calloc((size_t)st.st_size + 1, 1);
  if (!buf) die("alloc");
  ssize_t got = read(fd, buf, (size_t)st.st_size);
  if (got != st.st_size) die("source_read");
  close(fd);
  *size_out = (size_t)st.st_size;
  return buf;
}

static void validate_bundle(const char *buf) {
  if (!strstr(buf, "\"schema_version\":\"bundle-v3\"")) die("schema");
  if (!strstr(buf, "BRANCH_RCE_101")) die("missing_branch_rule_101");
  if (!strstr(buf, "BRANCH_RCE_102")) die("missing_branch_rule_102");
  if (!strstr(buf, "BRANCH_RCE_TEMPLATE_EXEC")) die("missing_branch_pattern_101");
  if (!strstr(buf, "BRANCH_RCE_DESERIALIZE_CHAIN")) die("missing_branch_pattern_102");
}

int main(int argc, char **argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: secscan-publish /work/path/to/current.bundle\n");
    return 2;
  }
  const char *source = argv[1];
  if (!starts_with(source, "/work/")) die("source_outside_work");

  size_t size = 0;
  char *buf = read_file(source, &size);
  validate_bundle(buf);

  struct passwd *pw = getpwnam("agentb");
  struct group *gr = getgrnam("secscan");
  if (!pw || !gr) die("lookup_secscan");

  char tmp[256];
  snprintf(tmp, sizeof(tmp), TARGET_DIR "/.branch-publish-%ld.tmp", (long)getpid());
  int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0600);
  if (fd < 0) die("target_tmp_open");
  size_t written = 0;
  while (written < size) {
    ssize_t n = write(fd, buf + written, size - written);
    if (n <= 0) die("target_write");
    written += (size_t)n;
  }
  if (fchown(fd, pw->pw_uid, gr->gr_gid) != 0) die("target_chown");
  if (fchmod(fd, 0640) != 0) die("target_chmod");
  if (fsync(fd) != 0) die("target_fsync");
  if (close(fd) != 0) die("target_close");
  if (rename(tmp, TARGET) != 0) die("target_rename");
  int dfd = open(TARGET_DIR, O_RDONLY | O_DIRECTORY);
  if (dfd >= 0) {
    fsync(dfd);
    close(dfd);
  }
  free(buf);
  printf("PUBLISH_OK=1 target=%s mode=0640 owner=agentb:secscan\n", TARGET);
  return 0;
}
