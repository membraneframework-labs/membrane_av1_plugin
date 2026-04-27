defmodule Membrane.AV1.Encoder do
  @moduledoc """
  AV1 Encoder based on STV-AV1 library.
  """
  use Membrane.Filter

  require Membrane.Logger

  alias Membrane.{AV1, Buffer, KeyframeRequestEvent, RawVideo}
  alias Membrane.AV1.Encoder.Native

  def_input_pad :input,
    accepted_format: %Membrane.RawVideo{pixel_format: :I420}

  def_output_pad :output,
    accepted_format: AV1

  def_options level: [
                spec: AV1.level() | :auto,
                default: :auto,
                description: """
                Determines the level of the encoded stream. If not provided, it
                will be automatically detected from the input stream.
                """
              ],
              encoder_mode: [
                spec: 0..13,
                default: 12,
                description: """
                Encoder preset. Higher values increase encoding speed and decrease quality.
                """
              ],
              rate_control: [
                spec:
                  {:cqp | :crf, quantization_parameter :: 0..63}
                  | {:cbr | :vbr, target_bitrate :: non_neg_integer()},
                default: {:cbr, 50},
                description: """
                Rate control mode used by the encoder:
                - CQP (Constant Quantization Parameter) - The same quantization parameter
                  is used for each frame. Higher values mean higher compression.
                - CRF (Constant Rate Factor) - Quantization parameter (which controls the compression level)
                is adjusted for each frame to maintain a certain level of perceived quality. Higher
                values mean higher compression.
                - CBR (Constant Bit Rate) - Provided bitrate is maintained for each frame
                  for the whole stream. Suitable for live-streaming.
                - VBR (Variable Bit Rate) - The encoder will aim to produce a stream with the
                  average bitrate of the provided value, varying the size of the output depending on
                  the complexity of the input.
                """
              ],
              framerate: [
                spec: AV1.framerate() | nil,
                default: nil,
                description: """
                Used by the encoder if not present in stream format. Framerate MUST be provided in one of these two places.
                """
              ],
              config_parameters: [
                spec: %{String.t() => String.t()},
                default: %{},
                description: """
                Parameters accepted by SVT-AV1 encoder. For possible values refer to
                EbSvtAv1EncConfiguration struct located in EbSvtAv1Enc.h.
                (https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Source/API/EbSvtAv1Enc.h)
                """
              ]

  @type encoded_frame :: %{payload: binary(), pts: non_neg_integer(), is_keyframe: boolean()}

  # The only profile currently supported by the encoder.
  @profile :main

  # Tier is always assumed to be main by the encoder.
  @tier :main

  @level_to_config_number %{
    auto: 0,
    "2.0": 20,
    "2.1": 21,
    "3.0": 30,
    "3.1": 31,
    "4.0": 40,
    "4.1": 41,
    "5.0": 50,
    "5.1": 51,
    "5.2": 52,
    "5.3": 53,
    "6.0": 60,
    "6.1": 61,
    "6.2": 62,
    "6.3": 63
  }

  defmodule FrameModifiers do
    @moduledoc false

    @type t :: %__MODULE__{
            force_keyframe: bool,
            change_height: integer(),
            change_width: integer(),
            change_framerate_numerator: integer(),
            change_framerate_denominator: integer()
          }

    defstruct force_keyframe: false,
              change_height: -1,
              change_width: -1,
              change_framerate_numerator: -1,
              change_framerate_denominator: -1
  end

  defmodule ConfigParameter do
    @moduledoc false

    @enforce_keys [:key, :value]

    defstruct @enforce_keys
  end

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            profile: AV1.profile(),
            tier: AV1.tier(),
            level: AV1.level(),
            encoder_mode: 0..13,
            options_framerate: AV1.framerate(),
            config_parameters: %{String.t() => String.t()},
            encoder_ref: reference() | nil,
            previous_input_stream_format: RawVideo.t() | nil,
            frame_modifiers: FrameModifiers.t()
          }

    @enforce_keys [
      :profile,
      :tier,
      :level,
      :encoder_mode,
      :options_framerate,
      :config_parameters,
      :frame_modifiers
    ]
    defstruct @enforce_keys ++
                [
                  encoder_ref: nil,
                  previous_input_stream_format: nil
                ]
  end

  @impl true
  def handle_init(_ctx, opts) do
    {[],
     %State{
       profile: @profile,
       tier: @tier,
       level: opts.level,
       encoder_mode: opts.encoder_mode,
       options_framerate: opts.framerate,
       config_parameters: opts.config_parameters,
       frame_modifiers: %FrameModifiers{}
     }}
  end

  @impl true
  def handle_stream_format(:input, stream_format, _ctx, %State{encoder_ref: nil} = state) do
    config_parameters_list =
      Enum.map(state.config_parameters, fn {key, value} ->
        %ConfigParameter{key: key, value: value}
      end)

    %RawVideo{framerate: {framerate_num, framerate_denom}} = stream_format
    resolve_framerate(stream_format, state.options_framerate)

    level = translate_level(state.level)

    {:ok, encoder_ref} =
      Native.create(
        stream_format.width,
        stream_format.height,
        framerate_num,
        framerate_denom,
        state.profile,
        state.tier,
        level,
        state.encoder_mode,
        config_parameters_list
      )

    output_stream_format =
      %Membrane.AV1{
        height: stream_format.height,
        width: stream_format.width,
        framerate: stream_format.framerate,
        profile: state.profile,
        tier: state.tier,
        level: state.level
      }

    {[stream_format: {:output, output_stream_format}], %State{state | encoder_ref: encoder_ref}}
  end

  @impl true
  def handle_stream_format(
        :input,
        new_input_stream_format,
        ctx,
        %State{encoder_ref: _initialized_encoder} = state
      ) do
    new_input_stream_format = resolve_framerate(new_input_stream_format, state.options_framerate)

    old_input_stream_format =
      resolve_framerate(ctx.pad_data[:input].stream_format, state.options_framerate)

    if old_input_stream_format != new_input_stream_format do
      frame_modifiers =
        update_frame_modifiers(
          state.frame_modifiers,
          old_input_stream_format,
          new_input_stream_format
        )

      output_stream_format = %Membrane.AV1{
        height: new_input_stream_format.height,
        width: new_input_stream_format.width,
        framerate: new_input_stream_format.framerate,
        profile: state.profile,
        tier: state.tier,
        level: state.level
      }

      {
        [stream_format: {:output, output_stream_format}],
        %State{state | frame_modifiers: frame_modifiers}
      }
    else
      {[], state}
    end
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, %State{} = state) do
    {:ok, encoded_frames} =
      Native.encode_frame(
        buffer.payload,
        buffer.pts,
        state.frame_modifiers,
        state.encoder_ref
      )

    buffers = get_buffers_from_frames(encoded_frames)

    {[buffer: {:output, buffers}], %State{state | frame_modifiers: %FrameModifiers{}}}
  end

  @impl true
  def handle_event(:output, %KeyframeRequestEvent{}, _ctx, %State{} = state) do
    {[], put_in(state.frame_modifiers.force_keyframe, true)}
  end

  @impl true
  def handle_event(:output, event, _ctx, state) do
    {[event: {:input, event}], state}
  end

  @impl true
  def handle_event(:input, event, _ctx, state) do
    {[event: {:output, event}], state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    {:ok, encoded_frames} = Native.flush(state.encoder_ref)
    buffers = get_buffers_from_frames(encoded_frames)
    {[buffer: {:output, buffers}, end_of_stream: :output], state}
  end

  @spec translate_level(Membrane.AV1.level() | :auto) :: non_neg_integer()
  defp translate_level(level) do
    case Map.get(@level_to_config_number, level) do
      nil -> raise "Level #{inspect(level)} is not valid"
      level_number -> level_number
    end
  end

  @spec resolve_framerate(RawVideo.t(), AV1.framerate()) :: RawVideo.t()
  defp resolve_framerate(%RawVideo{} = stream_format, options_framerate) do
    resolved_framerate =
      case {stream_format.framerate, options_framerate} do
        {nil, nil} ->
          raise "Framerate needs to be provided either with stream format or options"

        {nil, options_framerate} ->
          options_framerate

        {stream_format_framerate, nil} ->
          stream_format_framerate

        {stream_format_framerate, _options_framerate} ->
          Membrane.Logger.warning(
            "Framerate provided both with stream format and options, assuming
            value from stream format: #{inspect(stream_format_framerate)}"
          )
      end

    %RawVideo{stream_format | framerate: resolved_framerate}
  end

  @spec update_frame_modifiers(FrameModifiers.t(), RawVideo.t(), RawVideo.t()) ::
          FrameModifiers.t()
  defp update_frame_modifiers(
         %FrameModifiers{} = frame_modifiers,
         old_stream_format,
         new_stream_format
       ) do
    %RawVideo{
      width: old_width,
      height: old_height,
      framerate: {old_framerate_num, old_framerate_denom}
    } = old_stream_format

    %RawVideo{
      width: new_width,
      height: new_height,
      framerate: {new_framerate_num, new_framerate_denom}
    } = new_stream_format

    %FrameModifiers{
      frame_modifiers
      | change_width: if(old_width != new_width, do: new_width, else: -1),
        change_height: if(old_height != new_height, do: new_height, else: -1),
        change_framerate_numerator:
          if(old_framerate_num != new_framerate_num, do: new_framerate_num, else: -1),
        change_framerate_denominator:
          if(old_framerate_denom != new_framerate_denom, do: new_framerate_denom, else: -1)
    }
  end

  @spec get_buffers_from_frames([encoded_frame()]) :: [Buffer.t()]
  defp get_buffers_from_frames(encoded_frames) do
    Enum.map(encoded_frames, fn %{payload: payload, pts: pts, is_keyframe: is_keyframe} ->
      %Buffer{
        payload: payload,
        pts: Membrane.Time.nanoseconds(pts),
        metadata: %{av1: %{is_keyframe: is_keyframe}}
      }
    end)
  end
end
