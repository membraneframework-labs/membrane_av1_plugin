#pragma once
#include "svt-av1/EbSvtAv1.h"
#include "svt-av1/EbSvtAv1Enc.h"
#include <erl_nif.h>
#include <stdbool.h>

typedef struct State {
  EbComponentType *handle;
  unsigned int height;
  unsigned int width;
  unsigned int framerate_numerator;
  unsigned int framerate_denominator;
  PredStructure pred_structure;
} State;

#include "_generated/av1_encoder.h"
