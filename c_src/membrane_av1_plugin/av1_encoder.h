#pragma once

typedef struct State State;

#include "_generated/av1_encoder.h"
#include "svt-av1/EbSvtAv1.h"
#include "svt-av1/EbSvtAv1Enc.h"

#include <erl_nif.h>

struct State {
  EbComponentType *handle;
  unsigned int height;
  unsigned int width;
  framerate framerate;
  PredStructure pred_structure;
};
