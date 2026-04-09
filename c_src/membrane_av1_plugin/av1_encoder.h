#pragma once
#include "svt-av1/EbSvtAv1.h"
#include "svt-av1/EbSvtAv1Enc.h"
#include <erl_nif.h>

typedef struct State {
  EbComponentType *handle;
  EbSvtAv1EncConfiguration *config;
  // vpx_codec_ctx_t codec_context;
  // vpx_codec_iface_t *codec_interface;
  // vpx_image_t img;
  unsigned int encoding_deadline;
} State;

#include "_generated/av1_encoder.h"
