#ifndef IDFOSS_BRIDGING_H
#define IDFOSS_BRIDGING_H

#include <stdint.h>

// C ABI from native/vendor/iroh-c-ffi. Keep in sync with src/client.rs and
// src/daemon.rs; the library is the single source of truth.

// Runs the daemon to completion on the calling thread ("ctrl_c" clean
// shutdown never happens on iOS: the daemon lives with the process).
int idfon_daemon_run(const char *socket_path, const char *data_dir, const char *transport);

// One-shot JSON request/response over the daemon socket. Thread-safe; each
// call opens its own connection. On IDFON_OK, *out/*out_len hold a
// heap-allocated response body that the caller frees with
// idfon_client_result_free. ok (optional) receives 1/0 for response.ok.
int idfon_client_request(const char *socket_path, const uint8_t *req, uintptr_t req_len,
                         uint8_t **out, uintptr_t *out_len, uint8_t *ok, uint32_t connect_timeout_ms);

void idfon_client_result_free(uint8_t *ptr, uintptr_t len);

// idfon_client_socket_path(profile, out, cap) exists too; the app passes its
// own sandboxed socket path instead.

// Media pipeline (native/vendor/iroh-c-ffi src/media.rs + src/video.rs).
// Declared here instead of including irohnet.h (1338 lines); the static lib
// is the single source of truth. String results are heap-owned and freed
// with rust_free_string. Empty string return = failure (see
// media_live_last_error for the cause).
char *media_live_start(uint8_t audio, uint8_t video); // publish the selected tracks; (0,0) rejected. Returns ticket.
void media_live_stop(void);                  // stop own publish
uint8_t media_live_subscribe(char const *ticket); // hear the peer (decodes + plays)
void media_live_unsubscribe(void);
char *media_video_start(char const *ticket); // watch peer video -> video-frame.jpg path
void media_video_stop(void);
uint8_t media_live_set_audio_enabled(uint8_t enabled); // 0 = send silence (capture stays open)
uint8_t media_live_set_video_enabled(uint8_t enabled); // 0 = send no frames
char *media_live_last_error(void);           // last publish failure ("" if none)
void media_video_push_frame(const void *data, uintptr_t len, uint32_t width, uint32_t height, uint64_t pts_ms); // BGRA frame -> live encoder
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
