module Membrane.AV1.Decoder.Native

state_type "State"

type pixel_format :: :I420 | :I422 | :I444

type framerate :: %Framerate{
       numerator: unsigned,
       denominator: unsigned
     }

type encoded_frame :: %EncodedFrame{
       payload: payload,
       pts: int64,
       framerate: framerate
     }

type raw_frame :: %RawFrame{
       payload: payload,
       pts: int64,
       framerate: framerate,
       pixel_format: pixel_format,
       width: unsigned,
       height: unsigned
     }

spec create(n_threads :: unsigned, low_latency :: unsigned) ::
       {:ok :: label, state} | {:error :: label, reason :: string}

spec decode_frame(encoded_frame :: encoded_frame, state :: state) ::
       {:ok :: label, raw_frames :: [raw_frame]} | {:error :: label, reason :: string}

spec flush(state) ::
       {:ok :: label, frames :: [raw_frame]}
       | {:error :: label, reason :: string}

dirty :cpu, [:create, :decode_frame, :flush]
