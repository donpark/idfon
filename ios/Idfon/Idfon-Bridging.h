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
