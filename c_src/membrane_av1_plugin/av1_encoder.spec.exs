module Membrane.AV1.Encoder.Native

state_type "State"

type prediction_structure :: :all_intra | :low_delay | :random_access

type framerate :: %Framerate{
       numerator: unsigned,
       denominator: unsigned
     }

type encoded_frame :: %EncodedFrame{
       payload: payload,
       pts: int64,
       dts: int64,
       is_keyframe: bool
     }

type raw_frame :: %RawFrame{
       payload: payload,
       pts: int64,
       width: unsigned,
       height: unsigned,
       framerate: framerate
     }

type config_parameter :: %Membrane.AV1.Encoder.ConfigParameter{
       key: string,
       value: string
     }

spec create(
       width :: unsigned,
       height :: unsigned,
       framerate :: framerate,
       prediction_structure :: prediction_structure,
       config_parameters :: [config_parameter]
     ) :: {:ok :: label, state} | {:error :: label, reason :: string}

spec encode_frame(
       raw_frame :: raw_frame,
       force_keyframe :: bool,
       state
     ) ::
       {:ok :: label, frames :: [encoded_frame]}
       | {:error :: label, reason :: string}

spec flush(state) ::
       {:ok :: label, frames :: [encoded_frame]}
       | {:error :: label, reason :: string}

dirty :cpu, [:create, :encode_frame, :flush]
