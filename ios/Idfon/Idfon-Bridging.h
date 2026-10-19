#ifndef IDFOSS_BRIDGING_H
#define IDFOSS_BRIDGING_H

#include <stddef.h>
#include <stdint.h>


// C ABI from native/vendor/iroh-c-ffi. Keep in sync with src/client.rs and
// src/daemon.rs; the library is the single source of truth.

// Runs the daemon to completion on the calling thread ("ctrl_c" clean
// shutdown never happens on iOS: the daemon lives with the process).
int idfon_daemon_run(const char *socket_path, const char *data_dir, const char *transport);

// One-shot JSON request/response over the daemon socket (the RPC bridge to
// a separately-packaged daemon). Thread-safe; each call opens its own
// connection. On IDFON_OK, *out/*out_len hold a heap-allocated response body
// that the caller frees with idfon_client_result_free. ok (optional)
// receives 1/0 for response.ok.
int idfon_client_request(const char *socket_path, const uint8_t *req, uintptr_t req_len,
                         uint8_t **out, uintptr_t *out_len, uint8_t *ok, uint32_t connect_timeout_ms);

// One JSON request/response round-trip into the app's embedded feature set
// (the daemon core linked in-process — same functions the RPC bridge serves,
// no socket, no separate lifecycle). Same body and free conventions as
// idfon_client_request; ok (optional) receives 1/0 for response.ok.
// IDFON_ECONNECT = the feature set is still starting, retry.
int idfon_request(const uint8_t *req, uintptr_t req_len,
                  uint8_t **out, uintptr_t *out_len, uint8_t *ok);

void idfon_client_result_free(uint8_t *ptr, uintptr_t len);

// idfon_client_socket_path(profile, out, cap) exists too; the app passes its
// own sandboxed socket path instead.

// Media pipeline (native/vendor/iroh-c-ffi src/media.rs + src/video.rs).
// Declared here instead of including irohnet.h (1338 lines); the static lib
// is the single source of truth. String results are heap-owned and freed
// with rust_free_string. Empty string return = failure (see
// media_live_last_error for the cause).
char *media_live_start(uint8_t audio, uint8_t video); // publish the selected tracks; (0,0) rejected. Returns ticket.
// Same, but selects the audio source: "mic" (default capture device) or
// "push" (samples supplied through media_audio_push_samples). Makes the
// source a caller decision instead of a hardwired default input.
char *media_live_start_with_source(uint8_t audio, uint8_t video, char const *source);
char *media_live_start_with_profile(uint8_t audio, uint8_t video, char const *source, char const *codec, uint32_t sample_rate);
// Push mono f32 PCM at the sample rate selected for the active publisher.
void media_audio_push_samples(const float *pcm, size_t samples);
void media_live_stop(void);                  // stop own publish
uint8_t media_live_subscribe(char const *ticket); // hear the peer (decodes + plays)
void media_live_unsubscribe(void);
// Optional shell-owned audio playback. Register before media_live_subscribe;
// when set, decoded interleaved f32 PCM goes to the callback instead of the
// bundled output device. Frames are paced through the seam's jitter buffer.
// The buffer is borrowed (copy before returning); pts_us is 0 (the jitter
// buffer paces in order and carries no per-frame clock).
uint8_t media_audio_set_playback_cb(void const *ctx,
    void (*cb)(void const *ctx, uint8_t const *data, size_t len, uint32_t sample_rate, uint32_t channels, uint64_t pts_us));
void media_audio_clear_playback_cb(void);
char *media_video_start(char const *ticket); // watch peer video -> video-frame.jpg path
char *media_video_last_error(void);
void media_video_stop(void);
// Optional in-memory renderer. Register before media_video_start; when set,
// decoded RGBA frames go to the callback instead of video-frame.jpg. The
// buffer is borrowed (copy before returning); len == 0 means "clear".
uint8_t media_video_set_render_cb(void const *ctx,
    void (*cb)(void const *ctx, uint8_t const *data, size_t len, uint32_t width, uint32_t height, uint64_t pts_ms));
void media_video_clear_render_cb(void);
uint8_t media_live_set_audio_enabled(uint8_t enabled); // 0 = send silence (capture stays open)
uint8_t media_live_set_video_enabled(uint8_t enabled); // 0 = send no frames
char *media_live_last_error(void);           // last publish failure ("" if none)
void media_video_push_frame(const void *data, uintptr_t len, uint32_t width, uint32_t height, uint64_t pts_ms); // BGRA frame -> live encoder
void media_shutdown(void);
void iroh_enable_tracing(void);              // tracing -> /tmp/idfon-<pid>.log (IROH_C_LOG filter)
void rust_free_string(char *ptr);

// Apple on-device voice seam (native/vendor/iroh-c-ffi src/voice.rs +
// idfon-voice apple-ffi). The app registers its Swift engine once, then the
// Rust VoiceEngine drives it. selftest returns a transcript or "error:...";
// free with rust_free_string. PCM is s16 little-endian mono.
typedef uint8_t *(*idfon_voice_tts_fn)(const char *text, uint32_t *out_sample_rate, size_t *out_len);
typedef int32_t (*idfon_voice_stt_fn)(const uint8_t *pcm, size_t pcm_len, uint32_t sample_rate, char **out_text);
typedef void (*idfon_voice_free_fn)(uint8_t *ptr, size_t len);
typedef void (*idfon_voice_free_text_fn)(char *ptr);
int32_t idfon_voice_set_bindings(idfon_voice_tts_fn tts, idfon_voice_stt_fn stt,
                                 idfon_voice_free_fn free_bytes,
                                 idfon_voice_free_text_fn free_text);
char *idfon_voice_apple_selftest(void);
// Barge-in filter (P5): nonzero when `text` may cancel playback.
uint8_t idfon_voice_is_cancellable(const char *text, uint8_t playing, uint8_t in_tool_window);
// Text-layer echo check (P5): nonzero when `heard` is our own `spoken` text.
uint8_t idfon_voice_is_echo(const char *spoken, const char *heard);

// Turn rules (idfon_voice::turns via native/vendor/iroh-c-ffi src/voice.rs): the
// voice loop's decision seam, one session per conversation. JSON results are
// freed with rust_free_string, turn audio with idfon_voice_turn_free_audio.
// mode is "listen" or "speaking" (NULL = "listen"); audio is 16 kHz mono f32.
void *idfon_voice_turn_new(const char *thresholds_json); // NULL/empty = defaults, invalid = NULL
void idfon_voice_turn_free(void *sess);
void idfon_voice_turn_reset(void *sess); // heads' context restarts before the next hop
int32_t idfon_voice_turn_prev_state(const void *sess); // 0=LISTEN 1=HOLD 2=SPEAK 3=BACKCHANNEL
// Before a hop's frames (window sliding + turn audio); returns 1 when the
// heads' context must start over.
uint8_t idfon_voice_turn_begin_hop(void *sess, const float *user, const float *agent,
                                   size_t samples, const char *mode);
uint8_t idfon_voice_turn_switch_mode(void *sess, const char *mode);
void idfon_voice_turn_set_words(void *sess, const char *words); // user's words so far (ASR thread)
char *idfon_voice_turn_words_event(void *sess, const char *mode); // PARTIAL event JSON, or NULL
// One frame's decision: JSON {"events":[...],"final":bool,"reset":bool} (NULL
// on bad args). outputs = the 8-vector (state logits x4, hazard, yield, bc,
// p_end); left = the hop's frames after this one. When a turn ended, its audio
// goes to *out_audio/*out_audio_len (NULL/0 when none).
char *idfon_voice_turn_on_frame(void *sess, const float *outputs, double act_db, size_t left,
                                const char *mode, float **out_audio, size_t *out_audio_len);
void idfon_voice_turn_free_audio(float *ptr, size_t len);

// Voice-agent harness (crates/idfon-director): the on-device conversation
// director over yoagent + Apple Foundation Models (#34, docs/voice-agent-loop-contract.md).
// A null director means AFM is unavailable (OS floor / Apple Intelligence
// off) or the config is invalid; the caller falls back to the remote agent.
// Turn results are JSON (envelopes + trace record); free with
// idfon_director_free_string.
void *idfon_director_new_afm_config(const char *instructions, const char *config_json);
void *idfon_director_new_afm(const char *instructions);
// With a wrapped-agent callback: `voice_forward` delegates each turn to
// `forward` (the app forwards to the called idfon peer and blocks for the
// reply); `free_reply` releases the reply pointer. Run the director off the
// main thread: the callback blocks.
typedef int32_t (*idfon_director_forward_fn)(void *ctx, const char *text,
                                             const char *delegation_id, char **out_reply);
typedef void (*idfon_director_free_fn)(char *reply);
void *idfon_director_new_afm_wrapped(const char *instructions, const char *config_json,
                                     void *ctx, idfon_director_forward_fn forward,
                                     idfon_director_free_fn free_reply);
int32_t idfon_director_prewarm(void *director);
char *idfon_director_turn(void *director, const char *text); // (kept for the probe)

char *idfon_director_turn_input(void *director, const char *input_json);
void idfon_director_free(void *director);
void idfon_director_free_string(char *ptr);

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
