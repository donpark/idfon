#include "include/IdfonFFI.h"

// The on-device director (crates/idfon-director + its Apple Foundation Models
// shim) ships as libidfon_director.dylib with a macOS 26 floor (AFM3 paths
// gate themselves at macOS 27). It is dlopen'd on first use so the app links
// at macOS 14 without the dylib's newer objects. When the dylib is absent or
// refuses to load, the forwarders below report AFM-unavailable exactly like a
// null director, which every caller already handles.
#include <dlfcn.h>
#include <pthread.h>

static void *director_lib;
static pthread_once_t director_once = PTHREAD_ONCE_INIT;

static void load_director(void) {
    director_lib = dlopen("@executable_path/libidfon_director.dylib", RTLD_NOW | RTLD_LOCAL);
}

static void *director_symbol(const char *name) {
    pthread_once(&director_once, load_director);
    return director_lib ? dlsym(director_lib, name) : NULL;
}

// Each forwarder resolves its own name from the dylib. The cached pointer is
// written with the same value by any racing caller, so the benign race is
// safe.

void *idfon_director_new(const char *instructions) {
    static void *(*fn)(const char *);
    if (!fn) fn = director_symbol(__func__);
    return fn ? fn(instructions) : NULL;
}

void *idfon_director_new_afm(const char *instructions) {
    static void *(*fn)(const char *);
    if (!fn) fn = director_symbol(__func__);
    return fn ? fn(instructions) : NULL;
}

void *idfon_director_new_afm_config(const char *instructions, const char *config_json) {
    static void *(*fn)(const char *, const char *);
    if (!fn) fn = director_symbol(__func__);
    return fn ? fn(instructions, config_json) : NULL;
}

void *idfon_director_new_afm_wrapped(const char *instructions, const char *config_json,
                                     void *ctx, idfon_director_forward_fn forward,
                                     idfon_director_free_fn free_reply) {
    static void *(*fn)(const char *, const char *, void *, idfon_director_forward_fn,
                       idfon_director_free_fn);
    if (!fn) fn = director_symbol(__func__);
    return fn ? fn(instructions, config_json, ctx, forward, free_reply) : NULL;
}

int32_t idfon_director_prewarm(void *director) {
    static int32_t (*fn)(void *);
    if (!fn) fn = director_symbol(__func__);
    return fn ? fn(director) : -1;
}

char *idfon_director_turn(void *director, const char *text) {
    static char *(*fn)(void *, const char *);
    if (!fn) fn = director_symbol(__func__);
    return fn ? fn(director, text) : NULL;
}

char *idfon_director_turn_input(void *director, const char *input_json) {
    static char *(*fn)(void *, const char *);
    if (!fn) fn = director_symbol(__func__);
    return fn ? fn(director, input_json) : NULL;
}

void idfon_director_free(void *director) {
    static void (*fn)(void *);
    if (!fn) fn = director_symbol(__func__);
    if (fn) fn(director);
}

void idfon_director_free_string(char *ptr) {
    static void (*fn)(char *);
    if (!fn) fn = director_symbol(__func__);
    if (fn) fn(ptr);
}
