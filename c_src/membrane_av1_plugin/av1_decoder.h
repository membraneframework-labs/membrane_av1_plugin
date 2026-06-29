#pragma once
#include "dav1d/dav1d.h"

typedef struct State {
  Dav1dContext *handle;
} State;

#include "_generated/av1_decoder.h"
