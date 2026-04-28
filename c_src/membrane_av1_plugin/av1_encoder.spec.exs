module Membrane.AV1.Encoder.Native

state_type "State"

type prediction_structure :: :all_intra | :low_delay | :random_access

type encoded_frame :: %EncodedFrame{
       payload: payload,
       pts: int64,
       dts: int64,
       is_keyframe: bool
     }

type frame_modifiers :: %FrameModifiers{
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
       prediction_structure :: prediction_structure,
       config_parameters :: [config_parameter]
     ) :: {:ok :: label, state} | {:error :: label, reason :: atom}

spec encode_frame(
       payload,
       pts :: int64,
       force_keyframe :: bool,
       frame_modifiers :: frame_modifiers,
       state
     ) ::
       {:ok :: label, frames :: [encoded_frame]}
       | {:error :: label, reason :: atom}

spec flush(state) ::
       {:ok :: label, frames :: [encoded_frame]}
       | {:error :: label, reason :: atom}

dirty :cpu, [:create, :encode_frame, :flush]
