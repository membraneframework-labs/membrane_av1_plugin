#include "av1_encoder.h"
#include "membrane_av1_plugin/_generated/nif/av1_encoder.h"
#include "svt-av1/EbSvtAv1.h"
#include "svt-av1/EbSvtAv1Enc.h"
#include "unifex/unifex.h"
#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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

void free_frames(encoded_frame *frames, unsigned int frames_cnt) {
  for (unsigned int i = 0; i < frames_cnt; i++) {
    UnifexPayload *payload = frames[i].payload;
    if (payload != NULL) {
      unifex_payload_release(payload);
      unifex_free(payload);
    }
  }
  unifex_free(frames);
}

EbSvtIOFormat get_image_from_payload(UnifexPayload *payload, State *state) {
  uint32_t width = state->width;
  uint32_t height = state->height;

  size_t luma_size = (size_t)width * height;
  size_t chroma_size = (width / 2) * (height / 2);

  EbSvtIOFormat image = {
      .luma = payload->data,
      .cb = payload->data + luma_size,
      .cr = payload->data + luma_size + chroma_size,
      .y_stride = width,
      .cb_stride = width / 2,
      .cr_stride = width / 2,
  };
  return image;
}

UNIFEX_TERM create(
    UnifexEnv *env,
    unsigned int width,
    unsigned int height,
    unsigned int framerate_numerator,
    unsigned int framerate_denominator,
    Profile profile,
    Tier tier,
    unsigned int level,
    unsigned int encoder_mode,
    config_parameter *config_parameters,
    unsigned int config_parameters_length
) {
  State *state = unifex_alloc_state(env);
  EbSvtAv1EncConfiguration config;
  char error_buf[256];
  EbErrorType error_type;

  if ((error_type = svt_av1_enc_init_handle(&state->handle, &config))) {
    return result_error(
        env, "Error initializing encoder handle", error_type, create_result_error, state
    );
  }

  state->width = width;
  state->height = height;
  state->framerate_numerator = framerate_numerator;
  state->framerate_denominator = framerate_denominator;

  config.source_width = width;
  config.source_height = height;
  config.frame_rate_numerator = framerate_numerator;
  config.frame_rate_denominator = framerate_denominator;

  config.profile = (EbAv1SeqProfile)profile;
  config.tier = tier;
  config.level = level;
  config.enc_mode = encoder_mode;

  config.force_key_frames = true;
  config.intra_refresh_type = SVT_AV1_KF_REFRESH; // to force only closed GOP IDRs.

  for (unsigned int i = 0; i < config_parameters_length; i++) {
    char *key = config_parameters[i].key;
    char *value = config_parameters[i].value;

    if ((error_type = svt_av1_enc_parse_parameter(&config, key, value))) {
      snprintf(error_buf, sizeof(error_buf), "Error setting parameter %s: %s", key, value);
      return result_error(env, error_buf, error_type, create_result_error, state);
    }
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

void apply_frame_modifiers(frame_modifiers frame_modifiers, State *state) {
  if (frame_modifiers.change_width != -1) state->width = frame_modifiers.change_width;
  if (frame_modifiers.change_height != -1) state->height = frame_modifiers.change_height;
  if (frame_modifiers.change_framerate_numerator != -1)
    state->framerate_numerator = frame_modifiers.change_framerate_numerator;
  if (frame_modifiers.change_framerate_denominator != -1)
    state->framerate_denominator = frame_modifiers.change_framerate_denominator;
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
  if (priv_data_tail == NULL) {
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

EbPrivDataNode *build_priv_data(
    frame_modifiers frame_modifiers, bool *force_keyframe, UnifexState *state
) {
  EbPrivDataNode *priv_data_head = NULL;
  EbPrivDataNode *priv_data_tail = NULL;
  apply_frame_modifiers(frame_modifiers, state);

  if (frame_modifiers.change_height != -1 || frame_modifiers.change_width != -1) {

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

  if (frame_modifiers.change_framerate_numerator != -1 ||
      frame_modifiers.change_framerate_denominator != -1) {
    SvtAv1FrameRateInfo *framerate_change = malloc(sizeof(SvtAv1FrameRateInfo));
    *framerate_change = (SvtAv1FrameRateInfo){
        .frame_rate_numerator = state->framerate_numerator,
        .frame_rate_denominator = state->framerate_denominator,
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

UNIFEX_TERM get_encoded_frames(UnifexEnv *env, int flushing, UnifexState *state) {
  EbErrorType error_type;

  unsigned int frames_cnt = 0;
  unsigned int allocated_frames = 1;
  encoded_frame *encoded_frames = unifex_alloc(allocated_frames * sizeof(encoded_frame));
  EbBufferHeaderType *out_buffer;
  bool eos_sentinel_received = false;

  while ((error_type = svt_av1_enc_get_packet(state->handle, &out_buffer, flushing)) ==
             EB_ErrorNone &&
         out_buffer->n_filled_len > 0 && !eos_sentinel_received) {

    if (frames_cnt >= allocated_frames) {
      allocated_frames *= 2;
      encoded_frames = unifex_realloc(encoded_frames, allocated_frames * sizeof(encoded_frame));
    }

    encoded_frame *frame = &encoded_frames[frames_cnt];
    frame->payload = unifex_alloc(sizeof(UnifexPayload));
    unifex_payload_alloc(env, UNIFEX_PAYLOAD_BINARY, out_buffer->n_filled_len, frame->payload);
    memcpy(frame->payload->data, out_buffer->p_buffer, out_buffer->n_filled_len);
    frame->pts = out_buffer->pts;
    frame->dts = out_buffer->dts;
    frame->is_keyframe = out_buffer->pic_type == EB_AV1_KEY_PICTURE;

    eos_sentinel_received = out_buffer->flags & EB_BUFFERFLAG_EOS;
    svt_av1_enc_release_out_buffer(&out_buffer);

    frames_cnt++;
  }

  UNIFEX_TERM (*error_fun)(UnifexEnv *, const char *) =
      flushing ? flush_result_error : encode_frame_result_error;

  UNIFEX_TERM (*success_fun)(UnifexEnv *, encoded_frame const *, unsigned int) =
      flushing ? flush_result_ok : encode_frame_result_ok;

  UNIFEX_TERM result;

  if (error_type == EB_NoErrorEmptyQueue || error_type == EB_ErrorNone) {
    result = success_fun(env, encoded_frames, frames_cnt);
  } else {
    svt_av1_enc_release_out_buffer(&out_buffer);
    result = result_error(env, "Error retreiving encoded frame", error_type, error_fun, state);
  }

  free_frames(encoded_frames, frames_cnt);
  return result;
}

UNIFEX_TERM encode_frame(
    UnifexEnv *env,
    UnifexPayload *payload,
    int64_t pts,
    frame_modifiers frame_modifiers,
    UnifexState *state
) {
  EbErrorType error_type;
  bool force_keyframe;

  EbPrivDataNode *priv_data_head = build_priv_data(frame_modifiers, &force_keyframe, state);

  EbSvtIOFormat image = get_image_from_payload(payload, state);

  EbBufferHeaderType in_buffer = {
      .size = sizeof(EbBufferHeaderType),
      .p_buffer = (uint8_t *)&image,
      .n_filled_len = payload->size,
      .pts = pts,
      .pic_type = force_keyframe ? EB_AV1_KEY_PICTURE : EB_AV1_INVALID_PICTURE,
      .flags = 0,
      .p_app_private = priv_data_head
  };

  if ((error_type = svt_av1_enc_send_picture(state->handle, &in_buffer))) {
    return result_error(
        env, "Error sending image to the encoder", error_type, encode_frame_result_error, state
    );
  }

  free_priv_data(priv_data_head);

  return get_encoded_frames(env, 0, state);
}

UNIFEX_TERM flush(UnifexEnv *env, UnifexState *state) {
  svt_av1_enc_send_picture(
      state->handle,
      &(EbBufferHeaderType){
          .flags = EB_BUFFERFLAG_EOS,
          .pic_type = EB_AV1_INVALID_PICTURE,
      }
  );
  return get_encoded_frames(env, 1, state);
}
