#include "av1_decoder.h"
#include "dav1d/common.h"
#include "dav1d/dav1d.h"
#include "dav1d/picture.h"
#include "membrane_av1_plugin/_generated/nif/av1_decoder.h"
#include "unifex/payload.h"
#include "unifex/unifex.h"
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

size_t get_picture_size(Dav1dPicture picture) {

  size_t luma_size = picture.stride[0] * picture.p.h;

  int chroma_h;
  switch (picture.p.layout) {
  case DAV1D_PIXEL_LAYOUT_I400:
    chroma_h = 0;
    break;
  case DAV1D_PIXEL_LAYOUT_I420:
    chroma_h = (picture.p.h + 1) / 2;
    break;
  case DAV1D_PIXEL_LAYOUT_I422:
    chroma_h = picture.p.h;
    break;
  case DAV1D_PIXEL_LAYOUT_I444:
    chroma_h = picture.p.h;
    break;
  }

  size_t chroma_size = picture.stride[1] * chroma_h;
  return luma_size + 2 * chroma_size;
}

void convert_picture_to_raw_data(Dav1dPicture picture, UnifexPayload *raw_frame) {
  unsigned char *frame_data = raw_frame->data;

  int chroma_h;

  switch (picture.p.layout) {
  case DAV1D_PIXEL_LAYOUT_I400:
    chroma_h = 0;
    break;
  case DAV1D_PIXEL_LAYOUT_I420:
    chroma_h = (picture.p.h + 1) / 2;
    break;
  case DAV1D_PIXEL_LAYOUT_I422:
    chroma_h = picture.p.h;
    break;
  case DAV1D_PIXEL_LAYOUT_I444:
    chroma_h = picture.p.h;
    break;
  }

  memcpy(frame_data, picture.data[0], picture.stride[0] * picture.p.h);
  frame_data += picture.stride[0] * picture.p.h;

  memcpy(frame_data, picture.data[1], picture.stride[1] * chroma_h);
  frame_data += picture.stride[1] * chroma_h;
  memcpy(frame_data, picture.data[2], picture.stride[1] * chroma_h);
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
    output_frame->height = output_picture.p.h;
    output_frame->width = output_picture.p.w;
    output_frame->pts = output_picture.m.timestamp;
    output_frame->payload = unifex_alloc(sizeof(UnifexPayload));
    unifex_payload_alloc(
        env, UNIFEX_PAYLOAD_BINARY, get_picture_size(output_picture), output_frame->payload
    );
    convert_picture_to_raw_data(output_picture, output_frame->payload);
  }

  return result;
}

UNIFEX_TERM decode_frame(
    UnifexEnv *env, UnifexPayload *encoded_frame, int64_t pts, UnifexState *state
) {
  int result;
  Dav1dData data = {
      .data = encoded_frame->data, .sz = encoded_frame->size, .m = {.timestamp = pts}
  };

  if ((result = dav1d_send_data(state->handle, &data))) {
    return result_error(
        env, "Error sending data to the decoder", result, decode_frame_result_error, state
    );
  }

  raw_frame output_frame;

  switch ((result = get_decoded_frame(env, &output_frame, state))) {
  case 0:
    return decode_frame_result_ok(env, &output_frame, 1);
  case DAV1D_ERR(EAGAIN):
    return decode_frame_result_ok(env, NULL, 0);
  default:
    return result_error(
        env, "Error getting picture from decoder", result, decode_frame_result_error, state
    );
  }
}

UNIFEX_TERM flush(UnifexEnv *env, UnifexState *state) {
  unsigned int frames_length = 0;
  unsigned int allocated_frames = 1;
  raw_frame *raw_frames = unifex_alloc(allocated_frames * sizeof(raw_frame));

  int result;

  while ((result = get_decoded_frame(env, &raw_frames[frames_length], state))) {
    if (frames_length >= allocated_frames) {
      allocated_frames *= 2;
      raw_frames = unifex_realloc(raw_frames, allocated_frames * sizeof(raw_frame));
    }
    frames_length++;
  }

  if (result == DAV1D_ERR(EAGAIN)) {
    return flush_result_ok(env, raw_frames, frames_length);
  } else {
    free_frames(raw_frames, frames_length);
    return result_error(env, "Error flushing frames", result, flush_result_error, state);
  }
}
