#include "av1_decoder.h"
#include "dav1d/common.h"
#include "dav1d/dav1d.h"
#include "dav1d/headers.h"
#include "dav1d/picture.h"
#include "membrane_av1_plugin/_generated/nif/av1_decoder.h"
#include "unifex/payload.h"
#include "unifex/unifex.h"
#include <stdbool.h>
#include <stddef.h>
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
  UNIFEX_TERM result = result_error_fun(env, full_error_buf);
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

void get_payload_from_picture(UnifexEnv *env, Dav1dPicture picture, UnifexPayload *payload) {
  int chroma_h, chroma_w;
  switch (picture.p.layout) {
  case DAV1D_PIXEL_LAYOUT_I400:
    chroma_h = 0;
    chroma_w = 0;
    break;
  case DAV1D_PIXEL_LAYOUT_I420:
    chroma_h = (picture.p.h + 1) / 2;
    chroma_w = (picture.p.w + 1) / 2;
    break;
  case DAV1D_PIXEL_LAYOUT_I422:
    chroma_h = picture.p.h;
    chroma_w = (picture.p.w + 1) / 2;
    break;
  case DAV1D_PIXEL_LAYOUT_I444:
    chroma_h = picture.p.h;
    chroma_w = picture.p.w;
    break;
  }

  size_t luma_size = picture.p.w * picture.p.h;
  size_t chroma_size = chroma_w * chroma_h;
  size_t picture_size = luma_size + 2 * chroma_size;

  unifex_payload_alloc(env, UNIFEX_PAYLOAD_BINARY, picture_size, payload);

  void *picture_data = picture.data[0];
  unsigned char *frame_data = payload->data;

  for (int y = 0; y < picture.p.h; y++) {
    memcpy(frame_data, picture_data, picture.p.w);
    frame_data += picture.p.w;
    picture_data += picture.stride[0];
  }

  for (int plane = 1; plane < 3; plane++) {
    picture_data = picture.data[plane];
    for (int y = 0; y < chroma_h; y++) {
      memcpy(frame_data, picture_data, chroma_w);
      frame_data += chroma_w;
      picture_data += picture.stride[1];
    }
  }
}

void free_frames(raw_frame *frames, unsigned int frames_length) {
  for (unsigned int i = 0; i < frames_length; i++) {
    UnifexPayload *payload = frames[i].payload;
    if (payload != NULL) {
      unifex_payload_release(payload);
      unifex_free(payload);
    }
  }
  unifex_free(frames);
}

int get_decoded_frame(UnifexEnv *env, raw_frame *output_frame, UnifexState *state) {

  Dav1dPicture output_picture;
  int result = dav1d_get_picture(state->handle, &output_picture);

  if (result == 0) {
    if (output_picture.p.bpc != 8) {
      dav1d_picture_unref(&output_picture);
      return DAV1D_ERR(ENOTSUP);
    }

    switch (output_picture.p.layout) {
    case DAV1D_PIXEL_LAYOUT_I420:
      output_frame->pixel_format = PIXEL_FORMAT_I420;
      break;
    case DAV1D_PIXEL_LAYOUT_I422:
      output_frame->pixel_format = PIXEL_FORMAT_I422;
      break;
    case DAV1D_PIXEL_LAYOUT_I444:
      output_frame->pixel_format = PIXEL_FORMAT_I444;
      break;
    case DAV1D_PIXEL_LAYOUT_I400:
      dav1d_picture_unref(&output_picture);
      return DAV1D_ERR(ENOTSUP);
    }

    output_frame->height = output_picture.p.h;
    output_frame->width = output_picture.p.w;
    output_frame->pts = output_picture.m.timestamp;
    output_frame->payload = unifex_alloc(sizeof(UnifexPayload));
    get_payload_from_picture(env, output_picture, output_frame->payload);

    dav1d_picture_unref(&output_picture);
  }

  return result;
}

UNIFEX_TERM get_decoded_frames(UnifexEnv *env, bool flushing, UnifexState *state) {
  unsigned int frames_length = 0;
  unsigned int allocated_frames = 4;
  raw_frame *raw_frames = unifex_alloc(allocated_frames * sizeof(raw_frame));

  int result;

  while ((result = get_decoded_frame(env, &raw_frames[frames_length], state)) == 0) {
    frames_length++;
    if (frames_length >= allocated_frames) {
      allocated_frames *= 2;
      raw_frames = unifex_realloc(raw_frames, allocated_frames * sizeof(raw_frame));
    }
  }

  if (result == DAV1D_ERR(EAGAIN)) {
    if (flushing) return flush_result_ok(env, raw_frames, frames_length);
    else return decode_frame_result_ok(env, raw_frames, frames_length);
  } else {
    free_frames(raw_frames, frames_length);
    return result_error(
        env,
        "Error flushing frames",
        result,
        flushing ? flush_result_error : decode_frame_result_error,
        state
    );
  }
}

UNIFEX_TERM decode_frame(UnifexEnv *env, encoded_frame encoded_frame, UnifexState *state) {
  int result;
  Dav1dData data = {
      .data = encoded_frame.payload->data,
      .sz = encoded_frame.payload->size,
      .m = {.timestamp = encoded_frame.pts}
  };

  if ((result = dav1d_send_data(state->handle, &data))) {
    return result_error(
        env, "Error sending data to the decoder", result, decode_frame_result_error, state
    );
  }

  return get_decoded_frames(env, 0, state);
}

UNIFEX_TERM flush(UnifexEnv *env, UnifexState *state) { return get_decoded_frames(env, 1, state); }
