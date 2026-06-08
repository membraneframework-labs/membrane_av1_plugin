module Membrane.AV1.Decoder.Native

state_type "State"

type pixel_format :: :I420 | :I422 | :I444

type encoded_frame :: %EncodedFrame{
       payload: payload,
       pts: int64
     }

type raw_frame :: %RawFrame{
       payload: payload,
       pts: int64,
       pixel_format: pixel_format,
       width: unsigned,
       height: unsigned
     }

spec create(n_threads :: unsigned, low_latency :: bool) ::
       {:ok :: label, state} | {:error :: label, reason :: string}

spec decode_frame(encoded_frame :: encoded_frame, state :: state) ::
       {:ok :: label, raw_frames :: [raw_frame]} | {:error :: label, reason :: string}

spec flush(state) ::
       {:ok :: label, frames :: [raw_frame]}
       | {:error :: label, reason :: string}

dirty :cpu, [:create, :decode_frame, :flush]
