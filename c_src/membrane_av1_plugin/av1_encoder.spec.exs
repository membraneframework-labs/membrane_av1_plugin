module Membrane.AV1.Encoder.Native

state_type "State"

# type pixel_format :: :I420 | :I422 | :I444 | :NV12 | :YV12
type profile :: :main | :high | :professional

type tier :: :main | :high

type encoded_frame :: %EncodedFrame{
       payload: payload,
       pts: int64,
       dts: int64,
       is_keyframe: bool
     }

type frame_modifiers :: %FrameModifiers{
       force_keyframe: bool,
       change_height: int64,
       change_width: int64,
       change_framerate_numerator: int64,
       change_framerate_denominator: int64
     }

type config_parameter :: %Membrane.AV1.Encoder.ConfigParameter{
       key: string,
       value: string
     }

spec create(
       width :: unsigned,
       height :: unsigned,
       framerate_numerator :: unsigned,
       framerate_denominator :: unsigned,
       profile :: profile,
       tier :: tier,
       level :: unsigned,
       encoder_mode :: unsigned,
       # pixel_format,
       # encoding_deadline :: unsigned,
       # cpu_used :: int,
       config_parameters :: [config_parameter]
     ) :: {:ok :: label, state} | {:error :: label, reason :: atom}

spec encode_frame(payload, pts :: int64, frame_modifiers :: frame_modifiers, state) ::
       {:ok :: label, frames :: [encoded_frame]}
       | {:error :: label, reason :: atom}

spec flush(state) ::
       {:ok :: label, frames :: [encoded_frame]}
       | {:error :: label, reason :: atom}

dirty :cpu, [:create, :encode_frame, :flush]
