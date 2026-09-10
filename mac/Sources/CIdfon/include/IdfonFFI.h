#ifndef IDFOFFI_H
#define IDFOFFI_H

#include <stddef.h>
#include <stdint.h>

// C ABI from native/vendor/iroh-c-ffi. Hand-declared (same approach as the
// iOS bridging header) instead of including irohnet.h; the library is the
// single source of truth.

// --- idfond IPC client (src/client.rs) ---

// Resolves the daemon socket path for a profile. NULL/empty profile reads
// IDFON_PROFILE; "default" falls back to /tmp/idfon/idfond.sock, otherwise
// /tmp/idfon-{profile}/idfond.sock. Returns length excluding NUL, or -1.
int32_t idfon_client_socket_path(char const *profile, uint8_t *out, size_t cap);

// One-shot length-prefixed JSON request/response over the daemon socket.
// Thread-safe; each call opens its own connection. connect_timeout_ms = 0
// performs a single connect attempt; a positive value polls every 100 ms
// until the deadline. On IDFON_OK, *out/*out_len hold a heap-allocated
// response body freed with idfon_client_result_free; *ok mirrors Response.ok.
int32_t idfon_client_request(char const *socket_path, uint8_t const *req, size_t req_len,
                             uint8_t **out, size_t *out_len, uint8_t *ok, uint32_t connect_timeout_ms);

void idfon_client_result_free(uint8_t *ptr, size_t len);

// --- media pipeline (src/media.rs + src/video.rs) ---

// Own-media publish. Empty string return = failure (media_live_last_error
// holds the cause). Camera capture is shell-pushed: the app's
// AVCaptureSession (CameraPusher.swift) feeds BGRA frames via
// media_video_push_frame; the dylib encodes/publishes them.
char *media_live_start(void);                // publish microphone (cpal)
char *media_live_video_start(void);          // publish microphone + camera (shell-pushed)
void media_live_stop(void);                  // stop own publish
uint8_t media_live_subscribe(char const *ticket); // hear/watch a peer (decodes + plays)
void media_live_unsubscribe(void);
// Push one camera frame from the shell's AVCaptureSession into the dylib's
// encoder source (BGRA, tightly packed rows, 1280x720 on macOS).
void media_video_push_frame(uint8_t const *data, size_t len, uint32_t width, uint32_t height, uint64_t pts_ms);
// Watch peer video: subscribes, decodes, continuously rewrites the latest
// frame to <media dir>/video-frame.jpg (atomic rename). Returns the absolute
// frame path, or "" on failure.
char *media_video_start(char const *ticket);
void media_video_stop(void);
char *media_live_last_error(void);           // last publish failure ("" if none)

// Media file scope: subsequent media artifacts (video-frame.jpg, recordings,
// received.wav) land under <root>/conversations/<scope>/ instead of
// <root>/conversations/default/.
uint8_t media_set_scope(char const *scope);

// --- in-call recording (src/media.rs) ---

// Records the active live session's input via cpal to recording.opus.
uint8_t media_recording_start(void);
uint8_t media_recording_stop(void);
uint64_t media_recording_duration_ms(void);
// Packages the last recording into a blob; returns "duration_ms\nticket" or "".
char *media_live_recording_store(void);
uint8_t media_recording_persist(char const *ticket);

// --- audio controls (src/media.rs; cpal) ---

uint8_t media_audio_set_volume(uint8_t percent);           // 0..100
uint8_t media_audio_set_bitrate(uint32_t bitrate);         // 8000..510000 bps
size_t media_audio_output_count(void);
size_t media_audio_input_count(void);
uint64_t media_audio_probe(uint64_t duration_ms);          // input samples captured
uint8_t media_audio_switch_input(char const *device);
uint8_t media_audio_switch_output(char const *device);

// Halts every media session (mic, camera, playback, subscriptions).
void media_emergency_stop(void);

void media_shutdown(void);
void iroh_enable_tracing(void);              // tracing -> /tmp/idfon-<pid>.log (IROH_C_LOG filter)
void rust_free_string(char *ptr);

#define IDFON_OK 0
#define IDFON_EARG -1
#define IDFON_EREQUEST -2
#define IDFON_ECONNECT -3
#define IDFON_EWRITE -4
#define IDFON_EREAD -5
#define IDFON_ETOOLARGE -6
#define IDFON_EINVALID -7

#define IDFON_DAEMON_OK 0
#define IDFON_DAEMON_EARG -1
#define IDFON_DAEMON_EFAILED -2

#endif