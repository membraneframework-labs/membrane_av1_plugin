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

  def_options encoder_mode: [
                spec: 0..13,
                default: 8,
                description: """
                Encoder preset. Higher values increase encoding speed and decrease quality.
                """
              ],
              real_time_coding: [
                spec: boolean(),
                default: false,
                description: """
                Applies a set of speed and latency optimizations, so that the stream is
                more suitable for real-time applications. Forces `:low_delay` value for
                `:prediction_structure` option. It's intended to be used with CBR rate control
                (see `:rate_control` option).
                """
              ],
              rate_control: [
                spec: rate_control(),
                default: {:crf, 35},
                description: """
                Rate control mode used by the encoder:
                - CQP (Constant Quantization Parameter) - The same quantization parameter
                  is used for each frame. Higher values mean higher compression.
                - CRF (Constant Rate Factor) - Quantization parameter (which controls the compression level)
                is adjusted for each frame to maintain a certain level of perceived quality. Higher
                values mean higher compression.
                - CBR (Constant Bit Rate) - Provided bitrate is maintained for each frame
                  for the whole stream. Suitable for live-streaming. `:prediction_structure` option
                MUST be set to :low_delay.
                - VBR (Variable Bit Rate) - The encoder will aim to produce a stream with the
                  average bitrate of the provided value, varying the size of the output depending on
                  the complexity of the input.
                """
              ],
              prediction_structure: [
                spec: prediction_structure(),
                default: :random_access,
                description: """
                Prediction structure used when encoding the stream:
                - `:all_intra` - Every frame is an intra frame.
                - `:low_delay` - Frames can only reference previous frames. Additionally no frames
                  are buffered, each input frame will result in an encoded output frame.
                - `:random_access` - B-frames are allowed.
                """
              ],
              enable_forcing_keyframes: [
                spec: boolean(),
                default: true,
                description: """
                To enable the encoder to force keyframes, intra refresh points have to be true
                keyframes, not just intra-only frames, in order to make them independently decodable.
                This can lead to slightly worse performance.
                """
              ],
              level: [
                spec: AV1.level() | :auto,
                default: :auto,
                description: """
                Determines the level of the encoded stream. If not provided, it
                will be automatically detected from the input stream.
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
                https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Parameters.md
                ("Command line" column, without leading dashes.)
                """
              ]

  @type encoded_frame :: %{payload: binary(), pts: non_neg_integer(), is_keyframe: boolean()}

  @type prediction_structure :: :all_intra | :low_delay | :random_access

  @type rate_control ::
          {:cqp | :crf, quantization_parameter :: 0..63}
          | {:cbr | :vbr, target_bitrate :: non_neg_integer()}

  @level_config_param %{
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
            change_height: integer(),
            change_width: integer(),
            change_framerate_numerator: integer(),
            change_framerate_denominator: integer()
          }

    defstruct change_height: -1,
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
            # The encoder currently supports only :main profile, which is the default, so there's no
            # need to set it explicitly
            # profile: AV1.profile(),
            # The encoder always assumes :main tier, which is the default, so there's no
            # need to set it explicitly
            # tier: AV1.tier(),
            encoder_mode: 0..13,
            real_time_coding: boolean(),
            rate_control: AV1.Encoder.rate_control(),
            prediction_structure: AV1.Encoder.prediction_structure(),
            enable_forcing_keyframes: boolean(),
            level: AV1.level(),
            options_framerate: AV1.framerate(),
            config_parameters: %{String.t() => String.t()},
            encoder_ref: reference() | nil,
            previous_input_stream_format: RawVideo.t() | nil,
            frame_modifiers: FrameModifiers.t(),
            force_next_keyframe: boolean()
          }

    @enforce_keys [
      :encoder_mode,
      :real_time_coding,
      :rate_control,
      :prediction_structure,
      :enable_forcing_keyframes,
      :level,
      :options_framerate,
      :config_parameters,
      :frame_modifiers
    ]
    defstruct @enforce_keys ++
                [
                  encoder_ref: nil,
                  previous_input_stream_format: nil,
                  force_next_keyframe: false
                ]
  end

  @impl true
  def handle_init(_ctx, opts) do
    {[],
     %State{
       rate_control: opts.rate_control,
       encoder_mode: opts.encoder_mode,
       real_time_coding: opts.real_time_coding,
       prediction_structure: opts.prediction_structure,
       enable_forcing_keyframes: opts.enable_forcing_keyframes,
       level: opts.level,
       options_framerate: opts.framerate,
       config_parameters: opts.config_parameters,
       frame_modifiers: %FrameModifiers{}
     }}
  end

  @impl true
  def handle_stream_format(:input, stream_format, _ctx, %State{encoder_ref: nil} = state) do
    %RawVideo{framerate: {framerate_num, framerate_denom}} =
      stream_format =
      resolve_framerate(stream_format, state.options_framerate)

    level = translate_level(state.level)

    rate_control_params = translate_rate_control(state.rate_control)

    internal_config_parameters_list =
      [
        {"preset", Integer.to_string(state.encoder_mode)},
        {"rtc", if(state.real_time_coding, do: "1", else: "0")},
        {"irefresh-type", if(state.enable_forcing_keyframes, do: "2", else: "1")},
        {"level", Integer.to_string(level)}
        | rate_control_params
      ]
      |> Enum.map(fn {key, value} -> %ConfigParameter{key: key, value: value} end)

    user_config_parameters_list =
      Enum.map(state.config_parameters, fn {key, value} ->
        %ConfigParameter{key: key, value: value}
      end)

    {:ok, encoder_ref} =
      Native.create(
        stream_format.width,
        stream_format.height,
        framerate_num,
        framerate_denom,
        if(state.real_time_coding, do: :low_delay, else: state.prediction_structure),
        internal_config_parameters_list ++ user_config_parameters_list
      )

    output_stream_format =
      %Membrane.AV1{
        height: stream_format.height,
        width: stream_format.width,
        framerate: stream_format.framerate,
        profile: :main,
        tier: :main,
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
        profile: :main,
        tier: :main,
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
        state.force_next_keyframe,
        state.frame_modifiers,
        state.encoder_ref
      )

    buffers = get_buffers_from_frames(encoded_frames)

    {
      [buffer: {:output, buffers}],
      %State{state | frame_modifiers: %FrameModifiers{}, force_next_keyframe: false}
    }
  end

  @impl true
  def handle_event(:output, %KeyframeRequestEvent{}, _ctx, %State{} = state) do
    if state.enable_forcing_keyframes do
      {[], %State{state | force_next_keyframe: true}}
    else
      Membrane.Logger.warning(
        "Forcing keyframes not enabled, see :enable_forcing_keyframes option for details."
      )

      {[], state}
    end
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
    case Map.get(@level_config_param, level) do
      nil -> raise "Level #{inspect(level)} is not valid"
      level_number -> level_number
    end
  end

  @spec translate_rate_control(rate_control()) :: [{String.t(), String.t()}]
  defp translate_rate_control(rate_control) do
    case rate_control do
      {:cqp, quantization_parameter} ->
        [{"rc", "0"}, {"aq-mode", "0"}, {"qp", Integer.to_string(quantization_parameter)}]

      {:crf, quantization_parameter} ->
        [{"rc", "0"}, {"aq-mode", "2"}, {"qp", Integer.to_string(quantization_parameter)}]

      {:vbr, target_bitrate} ->
        [{"rc", "1"}, {"tbr", Integer.to_string(target_bitrate)}]

      {:cbr, target_bitrate} ->
        [{"rc", "2"}, {"tbr", Integer.to_string(target_bitrate)}]
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

          stream_format_framerate
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
    Enum.map(encoded_frames, fn %{payload: payload, pts: pts, dts: dts, is_keyframe: is_keyframe} ->
      %Buffer{
        payload: payload,
        pts: Membrane.Time.nanoseconds(pts),
        dts: Membrane.Time.nanoseconds(dts),
        metadata: %{av1: %{is_keyframe: is_keyframe}}
      }
    end)
  end
end
