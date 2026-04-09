#include "av1_encoder.h"
#include "membrane_av1_plugin/_generated/nif/av1_encoder.h"
#include "svt-av1/EbSvtAv1.h"
#include "svt-av1/EbSvtAv1Enc.h"
#include "unifex/unifex.h"
#include <stdio.h>
#include <string.h>

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
  EB_ErrorNone:
    error_string = "EB_ErrorNone";
    break;
  EB_DecUnsupportedBitstream:
    error_string = "EB_DecUnsupportedBitstream";
    break;
  EB_DecNoOutputPicture:
    error_string = "EB_DecNoOutputPicture";
    break;
  EB_DecDecodingError:
    error_string = "EB_DecDecodingError";
    break;
  EB_Corrupt_Frame:
    error_string = "EB_Corrupt_Frame";
    break;
  EB_ErrorInsufficientResources:
    error_string = "EB_ErrorInsufficientResources";
    break;
  EB_ErrorUndefined:
    error_string = "EB_ErrorUndefined";
    break;
  EB_ErrorInvalidComponent:
    error_string = "EB_ErrorInvalidComponent";
    break;
  EB_ErrorBadParameter:
    error_string = "EB_ErrorBadParameter";
    break;
  EB_ErrorDestroyThreadFailed:
    error_string = "EB_ErrorDestroyThreadFailed";
    break;
  EB_ErrorSemaphoreUnresponsive:
    error_string = "EB_ErrorSemaphoreUnresponsive";
    break;
  EB_ErrorDestroySemaphoreFailed:
    error_string = "EB_ErrorDestroySemaphoreFailed";
    break;
  EB_ErrorCreateMutexFailed:
    error_string = "EB_ErrorCreateMutexFailed";
    break;
  EB_ErrorMutexUnresponsive:
    error_string = "EB_ErrorMutexUnresponsive";
    break;
  EB_ErrorDestroyMutexFailed:
    error_string = "EB_ErrorDestroyMutexFailed";
    break;
  EB_NoErrorEmptyQueue:
    error_string = "EB_NoErrorEmptyQueue";
    break;
  EB_NoErrorFifoShutdown:
    error_string = "EB_NoErrorFifoShutdown";
    break;
  EB_ErrorMax:
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

UNIFEX_TERM create(
    UnifexEnv *env,
    unsigned int width,
    unsigned int height,
    config_parameter *config_parameters,
    unsigned int config_parameters_length
) {
  State *state = unifex_alloc_state(env);
  EbSvtAv1EncConfiguration config;
  UNIFEX_TERM result;
  char error_buf[256];
  EbErrorType error_type;

  if ((error_type = svt_av1_enc_init_handle(&state->handle, &config))) {
    return result_error(
        env, "Error initializing encoder handle", error_type, create_result_error, state
    );
  }

  for (int i = 0; i < config_parameters_length; i++) {
    char *key = config_parameters[i].key;
    char *value = config_parameters[i].value;

    if ((error_type = svt_av1_enc_parse_parameter(&config, key, value))) {
      snprintf(error_buf, sizeof(error_buf), "Error parsing parameter %s: %s", key, value);
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

  return result;
}
