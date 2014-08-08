#include <assert.h>
#include <endian.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <vector>

#include "image.h"

// Returns RMS difference between successive images as a 32-bit float, lsb first (intel style)
float rms_diff(Image img_a, Image img_b, int width, int height) {
  long long sumsq = 0;
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      for (int i = 0; i < 3; i++) {
	int delta = img_a.pixel(x,y)[i] - img_b.pixel(x,y)[i];
	sumsq += delta * delta;
      }
    }
  }
  float diff = sqrt((double) sumsq / (width * height));
  return diff;
}

void diff_filter(int width, int height) {
  Image last(width, height);
  Image current(width, height);
  Image next(width, height);

  if (!current.read(stdin)) {
    return;
  }

  printf("{\"values\":[");
  
  bool first = true;
  bool end = false;
  while (!end) {
    if (!next.read(stdin)) {
      end = true;
    }
    
    float diff;

    if (first) {
      diff = rms_diff(next, current, width, height);
    }
    else if (end) {
      diff = rms_diff(last, current, width, height);
    } else {
      float diff_last = rms_diff(last, current, width, height);
      float diff_next = rms_diff(next, current, width, height);
      if (diff_last < diff_next) {
        diff = diff_last;
      } else {
        diff = diff_next;
      }
    }

    assert(sizeof(unsigned int) == 4);
    
    if (!first) printf(",");
    first = false;
    printf("%.2f", diff);
    last = current;
    current = next;
  }
  printf("]}\n");
}

int main(int argc, char **argv) {
  int width = 0, height = 0;
  
  // Skip argv[0]
  argv++;

  // Parse args
  while (*argv) {
    if (!strcmp(argv[0], "--width")) {
      width = atoi(argv[1]);
      argv += 2;
    } else if (!strcmp(argv[0], "--height")) {
      height = atoi(argv[1]);
      argv += 2;
    } else {
      fprintf(stderr, "Unknown argument '%s'\n", argv[0]);
      exit(1);
    }
  }
  if (!width || !height) {
    fprintf(stderr, "Both --width and --height must be specified\n");
    exit(1);
  }
  
  diff_filter(width, height);

  return 0;
}
