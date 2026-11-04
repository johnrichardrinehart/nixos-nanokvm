// nanokvm-hold-disk diskN: refuse every macOS mount of diskN and its
// partitions until killed. Prints "ready" once Disk Arbitration consults it.
// flash-sd runs it while writing: otherwise macOS mounts the FAT partition
// read-write after each raw write and changes it (.fseventsd).
#include <DiskArbitration/DiskArbitration.h>
#include <stdio.h>
#include <string.h>

static const char *whole;

static DADissenterRef approve(DADiskRef disk, void *context) {
  (void)context;
  const char *name = DADiskGetBSDName(disk);
  size_t len = strlen(whole);
  if (name == NULL || strncmp(name, whole, len) != 0 ||
      (name[len] != '\0' && name[len] != 's'))
    return NULL;
  fprintf(stderr, "nanokvm-hold-disk: refused a mount of %s\n", name);
  return DADissenterCreate(kCFAllocatorDefault, kDAReturnExclusiveAccess,
                           CFSTR("nanokvm-flash-sd is writing this card"));
}

int main(int argc, char **argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: %s diskN\n", argv[0]);
    return 2;
  }
  whole = argv[1];
  DASessionRef session = DASessionCreate(kCFAllocatorDefault);
  if (session == NULL)
    return 1;
  DARegisterDiskMountApprovalCallback(session, NULL, approve, NULL);
  DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(),
                               kCFRunLoopDefaultMode);
  // Let the registration reach diskarbitrationd before reporting ready.
  CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.5, false);
  puts("ready");
  fflush(stdout);
  CFRunLoopRun();
  return 0;
}
