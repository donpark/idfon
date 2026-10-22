/* Idfond IPC client API (implemented in src/client.rs).
 * Hand-maintained: these functions use plain #[no_mangle] exports and are
 * therefore not picked up by safer-ffi's generated irohnet.h.
 *
 * Error codes (declared below).
 */

#ifndef __IDFON_CLIENT_H__
#define __IDFON_CLIENT_H__

#define IDFON_OK 0
#define IDFON_EARG (-1)
#define IDFON_EREQUEST (-2)
#define IDFON_ECONNECT (-3)
#define IDFON_EWRITE (-4)
#define IDFON_EREAD (-5)
#define IDFON_ETOOLARGE (-6)
#define IDFON_EINVALID (-7)

#ifdef __cplusplus
extern "C" {
#endif

#include <stddef.h>
#include <stdint.h>

/** \brief
 *  Resolves the daemon socket path for a profile. A NULL or empty profile
 *  reads the IDFON_PROFILE environment variable; "default", empty, invalid
 *  characters, or >64 chars fall back to /tmp/idfon/idfond.sock; otherwise
 *  the path is /tmp/idfon-{profile}/idfond.sock. Writes a NUL-terminated
 *  string into `out` and returns the length excluding the NUL, or -1 when
 *  `out` is null or `cap` is too small.
 */
int32_t
idfon_client_socket_path (
    char const * profile,
    uint8_t * out,
    size_t cap);

/** \brief
 *  Sends one length-prefixed request frame to the daemon and reads one
 *  response frame (one connection per call; thread-safe).
 *
 *  `req`/`req_len` is the already-encoded request JSON, forwarded verbatim.
 *  `connect_timeout_ms` = 0 performs a single connect attempt; a positive
 *  value polls every 100 ms until the deadline. Callers launch the daemon
 *  on -3 and retry with a positive window.
 *
 *  On success returns 0 and writes a heap-allocated response body to
 *  `*out`/`*out_len` (MUST be freed with idfon_client_result_free), and 0/1
 *  to `*ok` when non-null. JSON responses are validated against the protocol
 *  Response shape and `ok` mirrors Response.ok. The three *.compact methods
 *  (peers/identities/events) return raw binary payloads, passed through
 *  verbatim with ok = 1 (see idfond's connection loop).
 */
int32_t
idfon_client_request (
    char const * socket_path,
    uint8_t const * req,
    size_t req_len,
    uint8_t * * out,
    size_t * out_len,
    uint8_t * ok,
    uint32_t connect_timeout_ms);

/** \brief
 *  Frees a response buffer returned by idfon_client_request. Null is a
 *  no-op; `len` must be the value written to *out_len.
 */
void
idfon_client_result_free (
    uint8_t * ptr,
    size_t len);

/** \brief
 *  Runs the idfond daemon on the calling thread until it exits (ctrl_c or
 *  error). `socket_path` and `data_dir` must be non-null; `transport` may
 *  be NULL for the default ("iroh"; "fake" is the only other valid value).
 *  Returns 0 after a clean shutdown, -1 on a bad argument, -2 after an
 *  error (already printed to stderr).
 */
int32_t
idfon_daemon_run (
    char const * socket_path,
    char const * data_dir,
    char const * transport);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* __IDFON_CLIENT_H__ */
