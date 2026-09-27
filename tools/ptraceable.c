/* Allow any same-uid process to ptrace us (for eu-stack sampling), then exec.  */
#include <sys/prctl.h>
#include <unistd.h>
#include <stdio.h>
int main (int argc, char **argv)
{
  prctl (PR_SET_PTRACER, PR_SET_PTRACER_ANY, 0, 0, 0);
  execvp (argv[1], argv + 1);
  perror ("execvp");
  return 127;
}
