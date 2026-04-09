module Membrane.AV1.Encoder.Native

state_type "State"

# type pixel_format :: :I420 | :I422 | :I444 | :NV12 | :YV12

type encoded_frame :: %EncodedFrame{
       payload: payload,
       pts: int64,
       is_keyframe: bool
     }

#
# type user_encoder_config :: %UserEncoderConfig{
#        g_lag_in_frames: unsigned,
#        rc_target_bitrate: unsigned,
#        g_threads: int
#      }
#
type config_parameter :: %Membrane.AV1.Encoder.ConfigParameter{
       key: string,
       value: string
     }

spec create(
       width :: unsigned,
       height :: unsigned,
       # pixel_format,
       # encoding_deadline :: unsigned,
       # cpu_used :: int,
       config_parameters :: [config_parameter]
     ) :: {:ok :: label, state} | {:error :: label, reason :: atom}

spec encode_frame(payload, pts :: int64, force_keyframe :: bool, state) ::
       {:ok :: label, frames :: [encoded_frame]}
       | {:error :: label, reason :: atom}

spec flush(state) ::
       {:ok :: label, frames :: [encoded_frame]}
       | {:error :: label, reason :: atom}

dirty :cpu, [:create, :encode_frame, :flush]
