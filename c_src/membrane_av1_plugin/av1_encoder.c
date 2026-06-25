#define _POSIX_C_SOURCE 200112L

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "av1_encoder.h"
#include "svt-av1/EbSvtAv1.h"
#include "svt-av1/EbSvtAv1Enc.h"
#include "unifex/unifex.h"

typedef struct {
  encoded_frame *data;
  unsigned int length;
  unsigned int allocated;
} encoded_frame_vector;

encoded_frame_vector vector_init() {
  return (encoded_frame_vector){
      .length = 0, .allocated = 4, .data = unifex_alloc(4 * sizeof(encoded_frame))
  };
}

void vector_append(encoded_frame_vector *vec, encoded_frame frame) {
  if (vec->length >= vec->allocated) {
    vec->allocated *= 2;
    vec->data = unifex_realloc(vec->data, vec->allocated * sizeof(encoded_frame));
  }
  vec->data[vec->length] = frame;
  vec->length++;
}

void vector_free(encoded_frame_vector *vec) {
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

  svt_av1_enc_deinit(state->handle);
  svt_av1_enc_deinit_handle(state->handle);
}

UNIFEX_TERM result_error(
    UnifexEnv *env,
    const char *reason,
    EbErrorType error_type,
    UNIFEX_TERM (*result_error_fun)(UnifexEnv *, const char *),
    State *state
) {
  char *error_string;
  char full_error_buf[512];

  switch (error_type) {
  case EB_ErrorNone:
    error_string = "EB_ErrorNone";
    break;
  case EB_DecUnsupportedBitstream:
    error_string = "EB_DecUnsupportedBitstream";
    break;
  case EB_DecNoOutputPicture:
    error_string = "EB_DecNoOutputPicture";
    break;
  case EB_DecDecodingError:
    error_string = "EB_DecDecodingError";
    break;
  case EB_Corrupt_Frame:
    error_string = "EB_Corrupt_Frame";
    break;
  case EB_ErrorInsufficientResources:
    error_string = "EB_ErrorInsufficientResources";
    break;
  case EB_ErrorUndefined:
    error_string = "EB_ErrorUndefined";
    break;
  case EB_ErrorInvalidComponent:
    error_string = "EB_ErrorInvalidComponent";
    break;
  case EB_ErrorBadParameter:
    error_string = "EB_ErrorBadParameter";
    break;
  case EB_ErrorDestroyThreadFailed:
    error_string = "EB_ErrorDestroyThreadFailed";
    break;
  case EB_ErrorSemaphoreUnresponsive:
    error_string = "EB_ErrorSemaphoreUnresponsive";
    break;
  case EB_ErrorDestroySemaphoreFailed:
    error_string = "EB_ErrorDestroySemaphoreFailed";
    break;
  case EB_ErrorCreateMutexFailed:
    error_string = "EB_ErrorCreateMutexFailed";
    break;
  case EB_ErrorMutexUnresponsive:
    error_string = "EB_ErrorMutexUnresponsive";
    break;
  case EB_ErrorDestroyMutexFailed:
    error_string = "EB_ErrorDestroyMutexFailed";
    break;
  case EB_NoErrorEmptyQueue:
    error_string = "EB_NoErrorEmptyQueue";
    break;
  case EB_NoErrorFifoShutdown:
    error_string = "EB_NoErrorFifoShutdown";
    break;
  case EB_ErrorMax:
    error_string = "EB_ErrorMax";
    break;
  default:
    error_string = "Other error";
    break;
  }
  snprintf(full_error_buf, sizeof(full_error_buf), "%s: %s", reason, error_string);
  if (state) unifex_release_resource(state);

  UNIFEX_TERM result = result_error_fun(env, full_error_buf);
  return result;
}

EbSvtIOFormat get_image_from_raw_frame(raw_frame raw_frame) {
  // only YUV420 subsampling is supported
  size_t luma_size = (size_t)raw_frame.width * raw_frame.height;
  size_t chroma_size = (raw_frame.width / 2) * (raw_frame.height / 2);

  EbSvtIOFormat image = {
      .luma = raw_frame.payload->data,
      .cb = raw_frame.payload->data + luma_size,
      .cr = raw_frame.payload->data + luma_size + chroma_size,
      .y_stride = raw_frame.width,
      .cb_stride = raw_frame.width / 2,
      .cr_stride = raw_frame.width / 2,
  };
  return image;
}

UNIFEX_TERM create(
    UnifexEnv *env,
    unsigned int width,
    unsigned int height,
    framerate framerate,
    PredictionStructure prediction_structure,
    config_parameter *config_parameters,
    unsigned int config_parameters_length
) {
  State *state = unifex_alloc_state(env);
  EbSvtAv1EncConfiguration config;
  char error_buf[256];
  EbErrorType error_type;

  setenv("SVT_LOG", "2", 0); // Limit log severity to warnings

  if ((error_type = svt_av1_enc_init_handle(&state->handle, &config))) {
    return result_error(
        env, "Error initializing encoder handle", error_type, create_result_error, state
    );
  }

  state->width = width;
  state->height = height;
  state->framerate.numerator = framerate.numerator;
  state->framerate.denominator = framerate.denominator;
  state->pred_structure = (PredStructure)prediction_structure;

  config.source_width = width;
  config.source_height = height;
  config.frame_rate_numerator = framerate.numerator;
  config.frame_rate_denominator = framerate.denominator;
  config.pred_structure = (PredStructure)prediction_structure;

  for (unsigned int i = 0; i < config_parameters_length; i++) {
    char *key = config_parameters[i].key;
    char *value = config_parameters[i].value;

    if ((error_type = svt_av1_enc_parse_parameter(&config, key, value))) {
      snprintf(error_buf, sizeof(error_buf), "Error setting parameter %s: %s", key, value);
      return result_error(env, error_buf, error_type, create_result_error, state);
    }
  }
  if (!config.rtc && config.intra_refresh_type == SVT_AV1_KF_REFRESH &&
      config.pred_structure != LOW_DELAY && config.rate_control_mode != SVT_AV1_RC_MODE_CBR) {
    config.force_key_frames = true;
  }

  if ((error_type = svt_av1_enc_set_parameter(state->handle, &config))) {
    return result_error(
        env, "Error setting encoder parameters", error_type, create_result_error, state
    );
  }

  if ((error_type = svt_av1_enc_init(state->handle))) {
    return result_error(env, "Error initializing encoder", error_type, create_result_error, state);
  }

  return create_result_ok(env, state);
}

void append_priv_data_node(
    PrivDataType data_type,
    void *node_data,
    size_t data_size,
    EbPrivDataNode **priv_data_head,
    EbPrivDataNode **priv_data_tail
) {
  EbPrivDataNode *node = malloc(sizeof(EbPrivDataNode));
  *node =
      (EbPrivDataNode){.node_type = data_type, .data = node_data, .size = data_size, .next = NULL};

  if (*priv_data_head == NULL) *priv_data_head = node;
  if (*priv_data_tail == NULL) {
    *priv_data_tail = node;
  } else {
    (*priv_data_tail)->next = node;
    *priv_data_tail = node;
  }
}

void free_priv_data(EbPrivDataNode *priv_data_head) {
  while (priv_data_head) {
    EbPrivDataNode *priv_data_node = priv_data_head;
    priv_data_head = priv_data_node->next;
    free(priv_data_node->data);
    free(priv_data_node);
  }
}

EbPrivDataNode *build_priv_data(raw_frame raw_frame, int *force_keyframe, UnifexState *state) {
  EbPrivDataNode *priv_data_head = NULL;
  EbPrivDataNode *priv_data_tail = NULL;

  if (raw_frame.height != state->height || raw_frame.width != state->width) {
    state->height = raw_frame.height;
    state->width = raw_frame.width;

    SvtAv1InputPicDef *resolution_change = malloc(sizeof(SvtAv1InputPicDef));
    *resolution_change = (SvtAv1InputPicDef){
        .input_luma_width = state->width,
        .input_luma_height = state->height,
        .input_pad_bottom = 0,
        .input_pad_right = 0,
    };

    *force_keyframe = true; // Keyframe has to be forced for the update to take effect.

    append_priv_data_node(
        RES_CHANGE_EVENT,
        resolution_change,
        sizeof(SvtAv1InputPicDef),
        &priv_data_head,
        &priv_data_tail
    );
  }

  if (raw_frame.framerate.numerator != state->framerate.numerator ||
      raw_frame.framerate.denominator != state->framerate.denominator) {
    state->framerate.numerator = raw_frame.framerate.numerator;
    state->framerate.denominator = raw_frame.framerate.denominator;

    SvtAv1FrameRateInfo *framerate_change = malloc(sizeof(SvtAv1FrameRateInfo));
    *framerate_change = (SvtAv1FrameRateInfo){
        .frame_rate_numerator = state->framerate.numerator,
        .frame_rate_denominator = state->framerate.denominator,
    };

    append_priv_data_node(
        FRAME_RATE_CHANGE_EVENT,
        framerate_change,
        sizeof(SvtAv1FrameRateInfo),
        &priv_data_head,
        &priv_data_tail
    );
  }

  return priv_data_head;
}

EbErrorType get_encoded_frame(
    UnifexEnv *env,
    int flushing,
    encoded_frame *encoded_frame,
    bool *continue_draining,
    UnifexState *state
) {

  EbBufferHeaderType *out_buffer;
  EbErrorType result = svt_av1_enc_get_packet(state->handle, &out_buffer, flushing);

  switch (result) {
  case EB_ErrorNone:
    if (flushing) {
      *continue_draining = !(out_buffer->flags & EB_BUFFERFLAG_EOS);
    } else {
      *continue_draining = (state->pred_structure != LOW_DELAY);
    }

    if (out_buffer->n_filled_len == 0) {
      result = EB_NoErrorEmptyQueue;
    } else {
      encoded_frame->payload = unifex_alloc(sizeof(UnifexPayload));
      unifex_payload_alloc(
          env, UNIFEX_PAYLOAD_BINARY, out_buffer->n_filled_len, encoded_frame->payload
      );
      memcpy(encoded_frame->payload->data, out_buffer->p_buffer, out_buffer->n_filled_len);
      encoded_frame->pts = out_buffer->pts;
      encoded_frame->dts = out_buffer->dts;
      encoded_frame->is_keyframe = out_buffer->pic_type == EB_AV1_KEY_PICTURE;
    }
    svt_av1_enc_release_out_buffer(&out_buffer);
    break;
  case EB_NoErrorEmptyQueue:
    *continue_draining = false;
    break;
  default:
    *continue_draining = false;
    svt_av1_enc_release_out_buffer(&out_buffer);
    break;
  }

  return result;
}

EbErrorType get_encoded_frames(
    UnifexEnv *env, encoded_frame_vector *encoded_frames, int flushing, UnifexState *state
) {
  EbErrorType error_type;
  bool continue_draining;
  encoded_frame encoded_frame;

  // When not using LOW_DELAY, the decoder should be drained until svt_av1_enc_get_packet returns
  // EB_NoErrorEmptyQueue.
  // When using LOW_DELAY, svt_av1_enc_get_packet is blocking and is guaranteed to produce a
  // single frame to display, which can be accompanied by a number of alt-frames.
  //
  // When flushing the encoder, pic_send_done should be set to 1, which also makes
  // svt_av1_enc_get_packet blocking. The function should continue to be called until it produces an
  // EOS sentinel - a packet with EB_BUFFERFLAG_EOS flag. This packet can contain data, but doesn't
  // have to.
  do {
    error_type = get_encoded_frame(env, flushing, &encoded_frame, &continue_draining, state);
    if (error_type != EB_ErrorNone) break;
    vector_append(encoded_frames, encoded_frame);
  } while (continue_draining);

  return error_type;
}

UNIFEX_TERM encode_frame(
    UnifexEnv *env, raw_frame raw_frame, int force_keyframe, UnifexState *state
) {
  EbPrivDataNode *priv_data_head = build_priv_data(raw_frame, &force_keyframe, state);

  EbSvtIOFormat image = get_image_from_raw_frame(raw_frame);

  EbBufferHeaderType in_buffer = {
      .size = sizeof(EbBufferHeaderType),
      .p_buffer = (uint8_t *)&image,
      .n_filled_len = raw_frame.payload->size,
      .pts = raw_frame.pts,
      .pic_type = force_keyframe ? EB_AV1_KEY_PICTURE : EB_AV1_INVALID_PICTURE,
      .flags = 0,
      .p_app_private = priv_data_head
  };

  EbErrorType error_type = svt_av1_enc_send_picture(state->handle, &in_buffer);

  free_priv_data(priv_data_head);

  if (error_type) {
    return result_error(
        env, "Error sending image to the encoder", error_type, encode_frame_result_error, state
    );
  }
  encoded_frame_vector encoded_frame_vector = vector_init();
  error_type = get_encoded_frames(env, &encoded_frame_vector, 0, state);

  UNIFEX_TERM unifex_result;
  if (error_type == EB_NoErrorEmptyQueue || error_type == EB_ErrorNone) {
    unifex_result =
        encode_frame_result_ok(env, encoded_frame_vector.data, encoded_frame_vector.length);
  } else {
    unifex_result = result_error(
        env, "Error getting encoded frames", error_type, encode_frame_result_error, state
    );
  }
  vector_free(&encoded_frame_vector);
  return unifex_result;
}

UNIFEX_TERM flush(UnifexEnv *env, UnifexState *state) {
  EbErrorType error_type = svt_av1_enc_send_picture(
      state->handle,
      &(EbBufferHeaderType){
          .flags = EB_BUFFERFLAG_EOS,
          .pic_type = EB_AV1_INVALID_PICTURE,
      }
  );

  if (error_type) {
    return result_error(
        env, "Error sending EOS sentinel to the encoder", error_type, flush_result_error, state
    );
  }
  encoded_frame_vector encoded_frame_vector = vector_init();
  error_type = get_encoded_frames(env, &encoded_frame_vector, 1, state);

  UNIFEX_TERM unifex_result;
  if (error_type == EB_NoErrorEmptyQueue || error_type == EB_ErrorNone) {
    unifex_result = flush_result_ok(env, encoded_frame_vector.data, encoded_frame_vector.length);
  } else {
    unifex_result =
        result_error(env, "Error flushing the encoder", error_type, flush_result_error, state);
  }
  vector_free(&encoded_frame_vector);
  return unifex_result;
}
