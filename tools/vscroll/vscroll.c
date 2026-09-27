/* vscroll: emulate touchpad (finger-source) scrolling via zwlr_virtual_pointer_v1.
   usage: vscroll X Y SEG...   where each SEG is  DIR:SECONDS:RATE_HZ:VALUE
   DIR is d (content moves up; axis +) or u, or p (pause, no events).
   Every segment ends with axis_stop (like lifting fingers).  */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <wayland-client.h>
#include "wlr-virtual-pointer-unstable-v1-client-protocol.h"

static struct wl_seat *seat;
static struct zwlr_virtual_pointer_manager_v1 *mgr;

static void reg_global (void *d, struct wl_registry *r, uint32_t name,
			const char *iface, uint32_t ver)
{
  if (!strcmp (iface, wl_seat_interface.name) && !seat)
    seat = wl_registry_bind (r, name, &wl_seat_interface, 1);
  else if (!strcmp (iface, zwlr_virtual_pointer_manager_v1_interface.name))
    mgr = wl_registry_bind (r, name, &zwlr_virtual_pointer_manager_v1_interface, 1);
}
static void reg_remove (void *d, struct wl_registry *r, uint32_t n) {}
static const struct wl_registry_listener rl = { reg_global, reg_remove };

static uint32_t now_ms (void)
{
  struct timespec ts; clock_gettime (CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}
static void add_ns (struct timespec *t, long ns)
{
  t->tv_nsec += ns;
  while (t->tv_nsec >= 1000000000) { t->tv_nsec -= 1000000000; t->tv_sec++; }
}

int main (int argc, char **argv)
{
  if (argc < 4) { fprintf (stderr, "usage: vscroll X Y DIR:SEC:HZ:VAL...\n"); return 2; }
  struct wl_display *dpy = wl_display_connect (NULL);
  if (!dpy) { fprintf (stderr, "no display\n"); return 1; }
  struct wl_registry *reg = wl_display_get_registry (dpy);
  wl_registry_add_listener (reg, &rl, NULL);
  wl_display_roundtrip (dpy);
  if (!mgr) { fprintf (stderr, "no virtual pointer manager\n"); return 1; }
  struct zwlr_virtual_pointer_v1 *p
    = zwlr_virtual_pointer_manager_v1_create_virtual_pointer (mgr, seat);
  int x = atoi (argv[1]), y = atoi (argv[2]);
  /* Output layout bounding box, for motion_absolute.  */
  int lx = 0, ly = 0, lw = 1920, lh = 1080;
  if (getenv ("VSCROLL_LAYOUT"))
    sscanf (getenv ("VSCROLL_LAYOUT"), "%d,%d,%d,%d", &lx, &ly, &lw, &lh);
  x -= lx; y -= ly;
  /* Move away first so the target surface always gets pointer focus.  */
  zwlr_virtual_pointer_v1_motion_absolute (p, now_ms (), x - 40, y - 40, lw, lh);
  zwlr_virtual_pointer_v1_frame (p);
  wl_display_roundtrip (dpy);
  zwlr_virtual_pointer_v1_motion_absolute (p, now_ms (), x, y, lw, lh);
  zwlr_virtual_pointer_v1_frame (p);
  wl_display_flush (dpy);
  struct timespec t; clock_gettime (CLOCK_MONOTONIC, &t);
  add_ns (&t, 300000000);
  clock_nanosleep (CLOCK_MONOTONIC, TIMER_ABSTIME, &t, NULL);
  long total = 0;
  for (int i = 3; i < argc; i++)
    {
      char dir; double sec, hz = 100, val = 0;
      int nf = sscanf (argv[i], "%c:%lf:%lf:%lf", &dir, &sec, &hz, &val);
      if (nf != 4 && !(dir == 'p' && nf == 2))
	{ fprintf (stderr, "bad seg %s\n", argv[i]); return 2; }
      long n = (long) (sec * hz), period = (long) (1e9 / hz);
      clock_gettime (CLOCK_MONOTONIC, &t);
      for (long k = 0; k < n; k++)
	{
	  if (dir != 'p')
	    {
	      zwlr_virtual_pointer_v1_axis_source (p, WL_POINTER_AXIS_SOURCE_FINGER);
	      zwlr_virtual_pointer_v1_axis (p, now_ms (), WL_POINTER_AXIS_VERTICAL_SCROLL,
					    wl_fixed_from_double (dir == 'u' ? -val : val));
	      zwlr_virtual_pointer_v1_frame (p);
	      wl_display_flush (dpy);
	      total++;
	    }
	  add_ns (&t, period);
	  clock_nanosleep (CLOCK_MONOTONIC, TIMER_ABSTIME, &t, NULL);
	}
      if (dir != 'p')
	{
	  zwlr_virtual_pointer_v1_axis_source (p, WL_POINTER_AXIS_SOURCE_FINGER);
	  zwlr_virtual_pointer_v1_axis_stop (p, now_ms (), WL_POINTER_AXIS_VERTICAL_SCROLL);
	  zwlr_virtual_pointer_v1_frame (p);
	  wl_display_flush (dpy);
	  struct timespec rt; clock_gettime (CLOCK_REALTIME, &rt);
	  printf ("%.3f ", rt.tv_sec + rt.tv_nsec * 1e-9);
	  fflush (stdout);
	}
    }
  zwlr_virtual_pointer_v1_destroy (p);
  wl_display_roundtrip (dpy);
  wl_display_disconnect (dpy);
  printf ("\n"); fprintf (stderr, "%ld events\n", total);
  return 0;
}
