#include <ApplicationServices/ApplicationServices.h>
#include <CoreGraphics/CoreGraphics.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <math.h>
#include <sys/stat.h>
#include <unistd.h>
#include "RDDisplayTopology.h"

static int record_darkened_builtin(CGDirectDisplayID display, float brightness) {
    const char *user_home = getenv("HOME");
    if (!user_home) return 0;
    char directory[4096], marker[4096], temporary[4096];
    int n_dir = snprintf(directory, sizeof(directory), "%s/Library/Application Support/DisplayPanel", user_home);
    if (n_dir < 0 || (size_t)n_dir >= sizeof(directory)) return 0;
    mkdir(directory, 0700);
    int n_marker = snprintf(marker, sizeof(marker), "%s/disabled-builtin.json", directory);
    if (n_marker < 0 || (size_t)n_marker >= sizeof(marker)) return 0;
    int n_temp = snprintf(temporary, sizeof(temporary), "%s.XXXXXX", marker);
    if (n_temp < 0 || (size_t)n_temp >= sizeof(temporary)) return 0;
    int descriptor = mkstemp(temporary);
    if (descriptor < 0) return 0;
    FILE *file = fdopen(descriptor, "w");
    if (!file) { close(descriptor); unlink(temporary); return 0; }
    int written = fprintf(file, "{\"id\":%u,\"brightness\":%.6f}", display, brightness) > 0;
    int closed = fclose(file) == 0;
    if (!written || !closed || rename(temporary, marker) != 0) { unlink(temporary); return 0; }
    return 1;
}

static int usable_external(void) {
    RDTopology topology = RDReadSystemTopology();
    return RDUsableExternalCount(&topology) > 0 ? 1 : 0;
}

extern int DisplayServicesGetBrightness(CGDirectDisplayID display, float *brightness);
extern int DisplayServicesSetBrightness(CGDirectDisplayID display, float brightness);
extern int DisplayServicesIsBuiltInDisplay(CGDirectDisplayID display);

static CGDirectDisplayID find_builtin(void) {
    CGDirectDisplayID displays[16];
    uint32_t count = 0;
    if (CGGetOnlineDisplayList(16, displays, &count) != kCGErrorSuccess) return 0;
    for (uint32_t i = 0; i < count; i++) {
        if (DisplayServicesIsBuiltInDisplay(displays[i])) return displays[i];
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s get | set VALUE(0-1)\n", argv[0]);
        return 1;
    }

    CGDirectDisplayID d = find_builtin();
    if (!d) return 4;

    if (strcmp(argv[1], "get") == 0) {
        float b = -1.0f;
        for (int attempt = 0; attempt < 5; attempt++) {
            if (DisplayServicesGetBrightness(d, &b) == 0 && isfinite(b) && b >= 0.0f && b <= 1.0f) {
                printf("%.6f\n", b);
                return 0;
            }
            usleep(60000);
        }
        return 2;
    }
    if (strcmp(argv[1], "set") == 0 && argc > 2) {
        char *end = NULL;
        float v = strtof(argv[2], &end);
        if (!end || end == argv[2] || *end || !isfinite(v)) return 1;
        if (v < 0.0f) v = 0.0f;
        if (v > 1.0f) v = 1.0f;
        if (v <= 0.01f && !usable_external()) {
            fprintf(stderr, "No usable external display; preserving builtin visibility\n");
            return 5;
        }
        float previous = 0.5f;
        if (v <= 0.01f) {
            if (DisplayServicesGetBrightness(d, &previous) != 0 || !isfinite(previous) || previous < 0 || previous > 1) return 2;
            if (!record_darkened_builtin(d, previous)) return 5;
        }
        if (DisplayServicesSetBrightness(d, v) == 0) {
            if (v <= 0.01f && !usable_external()) {
                DisplayServicesSetBrightness(d, fmaxf(previous, 0.5f));
                return 5;
            }
            printf("ok %.6f\n", v);
            return 0;
        }
        return 3;
    }
    return 1;
}
