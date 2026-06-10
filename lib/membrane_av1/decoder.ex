defmodule Membrane.AV1.Decoder do
  @moduledoc """
  AV1 Decoder based on dav1d library.
  """
  use Membrane.Filter

  require Membrane.Logger

  alias Membrane.{AV1, RawVideo}
  alias Membrane.AV1.Decoder.Native
  alias Membrane.Buffer

  def_input_pad :input,
    accepted_format: AV1

  def_output_pad :output,
    accepted_format: %RawVideo{aligned: true}

  def_options threads: [
                spec: pos_integer() | :auto,
                default: :auto,
                description: """
                Number of threads that the decoder will use. If set to `:auto` then the number of
                logical cores in the host system will be assumed.
                """
              ],
              low_latency: [
                spec: boolean(),
                default: false,
                description: """
                Determines whether the decoder will operate in low latency mode.
                """
              ]

  defmodule EncodedFrame do
    @moduledoc false

    @type t :: %__MODULE__{
            payload: binary(),
            pts: integer()
          }
    @enforce_keys [:payload, :pts]

    defstruct @enforce_keys
  end

  defmodule RawFrame do
    @moduledoc false

    @type t :: %__MODULE__{
            payload: binary(),
            pts: integer(),
            pixel_format: RawVideo.pixel_format(),
            width: non_neg_integer(),
            height: non_neg_integer()
          }
    @enforce_keys [:payload, :pts, :pixel_format, :width, :height]

    defstruct @enforce_keys
  end

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{decoder_ref: reference(), framerate: AV1.framerate()}

    @enforce_keys [:decoder_ref]
    defstruct @enforce_keys ++
                [
                  framerate: nil
                ]
  end

  @impl true
  def handle_init(_ctx, opts) do
    n_threads =
      case opts.threads do
        :auto -> 0
        n -> n
      end

    {:ok, decoder_ref} = Native.create(n_threads, opts.low_latency)
    {[], %State{decoder_ref: decoder_ref}}
  end

  @impl true
  def handle_stream_format(:input, stream_format, _ctx, %State{} = state) do
    {[], %State{state | framerate: stream_format.framerate}}
  end

  @impl true
  def handle_buffer(:input, buffer, ctx, state) do
    case Native.decode_frame(
           %EncodedFrame{payload: buffer.payload, pts: buffer.pts},
           state.decoder_ref
         ) do
      {:ok, raw_frames} ->
        actions = get_actions_from_frames(raw_frames, ctx.pads[:output].stream_format, state)
        {actions, state}

      {:error, reason} ->
        raise "Error decoding frame: #{inspect(reason)}"
    end
  end

  @impl true
  def handle_end_of_stream(:input, ctx, state) do
    case Native.flush(state.decoder_ref) do
      {:ok, raw_frames} ->
        actions = get_actions_from_frames(raw_frames, ctx.pads[:output].stream_format, state)

        {actions ++ [end_of_stream: :output], state}

      {:error, reason} ->
        raise "Error flushing the decoder: #{inspect(reason)}"
    end
  end

  @spec get_actions_from_frames([RawFrame.t()], RawVideo.t() | nil, State.t()) :: [
          Membrane.Element.Action.buffer() | Membrane.Element.Action.stream_format()
        ]
  defp get_actions_from_frames(raw_frames, current_stream_format, state) do
    {actions, _stream_format} =
      Enum.flat_map_reduce(
        raw_frames,
        current_stream_format,
        &get_actions_from_frame(&1, &2, state)
      )

    actions
  end

  @spec get_actions_from_frame(RawFrame.t(), RawVideo.t() | nil, State.t()) ::
          {[Membrane.Element.Action.buffer() | Membrane.Element.Action.stream_format()],
           RawVideo.t()}
  defp get_actions_from_frame(raw_frame, current_stream_format, state) do
    buffer_action = [
      buffer: {:output, %Buffer{payload: raw_frame.payload, pts: raw_frame.pts}}
    ]

    case maybe_get_new_stream_format(current_stream_format, raw_frame, state) do
      nil ->
        {buffer_action, current_stream_format}

      new_stream_format ->
        {[stream_format: {:output, new_stream_format}] ++ buffer_action, new_stream_format}
    end
  end

  @spec maybe_get_new_stream_format(RawVideo.t() | nil, RawFrame.t(), State.t()) ::
          RawVideo.t() | nil
  defp maybe_get_new_stream_format(current_stream_format, raw_frame, state) do
    common_keys = [:pixel_format, :width, :height]

    if current_stream_format == nil or
         Map.take(current_stream_format, common_keys) != Map.take(raw_frame, common_keys) or
         state.framerate not in [nil, current_stream_format.framerate] do
      %RawVideo{
        width: raw_frame.width,
        height: raw_frame.height,
        pixel_format: raw_frame.pixel_format,
        aligned: true,
        framerate: state.framerate
      }
    else
      nil
    end
  end
end
