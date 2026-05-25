#include "av1_decoder.h"
#include "dav1d/common.h"
#include "dav1d/dav1d.h"
#include "unifex/unifex.h"
#include <stdint.h>
#include <string.h>

void handle_destroy_state(UnifexEnv *env, State *state) {
  UNIFEX_UNUSED(env);

  dav1d_close(&state->handle);
}

UNIFEX_TERM result_error(
    UnifexEnv *env,
    const char *reason,
    int dav1d_error,
    UNIFEX_TERM (*result_error_fun)(UnifexEnv *, const char *),
    State *state
) {
  char full_error_buf[512];
  snprintf(
      full_error_buf, sizeof(full_error_buf), "%s: %s", reason, strerror(DAV1D_ERR(dav1d_error))
  );
  if (state) unifex_release_resource(state);
  UNIFEX_TERM result = result_error_fun(env, reason);
  return result;
}

UNIFEX_TERM create(UnifexEnv *env, unsigned int n_threads, int low_latency) {
  State *state = unifex_alloc_state(env);
  int result;

  Dav1dSettings settings;
  dav1d_default_settings(&settings);
  settings.n_threads = n_threads;
  settings.max_frame_delay = low_latency;

  if ((result = dav1d_open(&state->handle, &settings))) {
    return result_error(env, "Error initializing decoder", result, create_result_error, state);
  }

  return create_result_ok(env, state);
}

void free_unifex_payload() {}

UNIFEX_TERM decode_frame(
    UnifexEnv *env, UnifexPayload *encoded_frame, int64_t pts, UnifexState *state
) {
  int result;
  Dav1dData data = {
      .data = encoded_frame->data, .sz = encoded_frame->size, .m = {.timestamp = pts}
  };

  Dav1dPicture result_frame;

  if ((result = dav1d_send_data(state->handle, &data))) {
    return result_error(
        env, "Error sending data to the decoder", result, decode_frame_result_error, state
    );
  }

  result = dav1d_get_picture(state->handle, &result_frame);

  switch (result) { case 0: }
}
