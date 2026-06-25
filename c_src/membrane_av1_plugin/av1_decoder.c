#include "av1_decoder.h"
#include "dav1d/common.h"
#include "dav1d/data.h"
#include "dav1d/dav1d.h"
#include "dav1d/headers.h"
#include "dav1d/picture.h"
#include "membrane_av1_plugin/_generated/nif/av1_decoder.h"
#include "membrane_av1_plugin/_generated/nif/av1_decoder_types.h"
#include "unifex/payload.h"
#include "unifex/unifex.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

typedef struct {
  raw_frame *data;
  unsigned int length;
  unsigned int allocated;
} raw_frame_vector;

raw_frame_vector vector_init() {
  return (raw_frame_vector){
      .length = 0, .allocated = 4, .data = unifex_alloc(4 * sizeof(raw_frame))
  };
}

void vector_append(raw_frame_vector *vec, raw_frame frame) {
  if (vec->length >= vec->allocated) {
    vec->allocated *= 2;
    vec->data = unifex_realloc(vec->data, vec->allocated * sizeof(raw_frame));
  }
  vec->data[vec->length] = frame;
  vec->length++;
}

void vector_free(raw_frame_vector *vec) {
  for (unsigned int i = 0; i < vec->length; i++) {
    UnifexPayload *payload = vec->data[i].payload;
    if (payload != NULL) {
      unifex_payload_release(payload);
      unifex_free(payload);
    }
  }
  unifex_free(vec->data);
  vec->data = NULL;
  vec->allocated = 0;
  vec->length = 0;
}

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

UNIFEX_TERM create(UnifexEnv *env, unsigned int n_threads, unsigned int max_frame_delay) {
  State *state = unifex_alloc_state(env);
  int result;

  Dav1dSettings settings;
  dav1d_default_settings(&settings);
  settings.n_threads = n_threads;
  settings.max_frame_delay = max_frame_delay;

  if ((result = dav1d_open(&state->handle, &settings))) {
    return result_error(env, "Error initializing decoder", result, create_result_error, state);
  }

  return create_result_ok(env, state);
}

void get_payload_from_picture(UnifexEnv *env, Dav1dPicture picture, UnifexPayload *payload) {
  int chroma_h = 0, chroma_w = 0;
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

  unsigned char *picture_data = picture.data[0];
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
    output_frame->framerate = *(framerate *)output_picture.m.user_data.data;
    output_frame->payload = unifex_alloc(sizeof(UnifexPayload));
    get_payload_from_picture(env, output_picture, output_frame->payload);

    dav1d_picture_unref(&output_picture);
  }

  return result;
}

int get_decoded_frames(UnifexEnv *env, raw_frame_vector *raw_frames, UnifexState *state) {
  int result;
  raw_frame decoded_frame;

  while ((result = get_decoded_frame(env, &decoded_frame, state)) == 0) {
    vector_append(raw_frames, decoded_frame);
  }
  return result;
}

int decode_data(
    UnifexEnv *env, Dav1dData data, raw_frame_vector *decoded_frames, UnifexState *state
) {
  int result = dav1d_send_data(state->handle, &data);

  // DAV1D_ERR(EAGAIN) returned from dav1d_send_data means that the decoder should
  // first be drained, then the call should be retried.
  // DAV1D_ERR(EAGAIN) returned from dav1d_get_picture means that there are no more decoded
  // frames ready to be received and the decoder should be provided with a new encoded
  // frame. If despite that the function is called again, it signals EOS to the decoder and all
  // buffered frames can be received.
  switch (result) {
  case DAV1D_ERR(EAGAIN):
    result = get_decoded_frames(env, decoded_frames, state);
    if (result == DAV1D_ERR(EAGAIN)) return decode_data(env, data, decoded_frames, state);
    else return result;
  case 0:
    return get_decoded_frames(env, decoded_frames, state);
  default:
    dav1d_data_unref(&data);
    return result;
  }
}

void free_framerate_callback(const uint8_t *framerate_data, void *cookie) {
  UNIFEX_UNUSED(cookie);
  unifex_free((void *)framerate_data);
}

Dav1dData create_data(encoded_frame encoded_frame) {
  Dav1dData data = {
      .data = encoded_frame.payload->data,
      .sz = encoded_frame.payload->size,
      .m = {.timestamp = encoded_frame.pts}
  };
  framerate *fr = unifex_alloc(sizeof(framerate));
  *fr = encoded_frame.framerate;
  dav1d_data_wrap_user_data(&data, (const uint8_t *)fr, free_framerate_callback, NULL);
  return data;
}

UNIFEX_TERM decode_frame(UnifexEnv *env, encoded_frame encoded_frame, UnifexState *state) {
  raw_frame_vector decoded_frames = vector_init();
  Dav1dData data = create_data(encoded_frame);
  int result = decode_data(env, data, &decoded_frames, state);

  UNIFEX_TERM unifex_result;
  if (result == DAV1D_ERR(EAGAIN)) {
    unifex_result = decode_frame_result_ok(env, decoded_frames.data, decoded_frames.length);
  } else {
    unifex_result =
        result_error(env, "Error decoding frame", result, decode_frame_result_error, state);
  }
  vector_free(&decoded_frames);
  return unifex_result;
}

UNIFEX_TERM flush(UnifexEnv *env, UnifexState *state) {
  raw_frame_vector decoded_frames = vector_init();

  int result = get_decoded_frames(env, &decoded_frames, state);
  UNIFEX_TERM unifex_result;
  if (result == DAV1D_ERR(EAGAIN)) {
    unifex_result = flush_result_ok(env, decoded_frames.data, decoded_frames.length);
  } else {
    unifex_result =
        result_error(env, "Error flushing the decoder", result, flush_result_error, state);
  }
  vector_free(&decoded_frames);
  return unifex_result;
}
