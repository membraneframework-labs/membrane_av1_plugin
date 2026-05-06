defmodule Membrane.AV1.Encoder do
  @moduledoc """
  AV1 Encoder based on SVT-AV1 library. It expects each buffer to contain a single raw frame.

  The encoder supports stream formats changing resolution on the fly when the following contitions
  are met:
  - New resolution is not greater than the previous one.
  - Low-Delay mode is set (see option `:prediction_structure`).
  - New luma width and height less than 64.
  - `:intra_refresh_type` is set to `:closed_gop`.

  Keyframes can be forced with `t:Membrane.KeyframeRequestEvent.t/0` events when
  `:intra_refresh_type` option is set to `:closed_gop` and `:rate_control` is not VBR.
  """
  use Membrane.Filter

  require Membrane.Logger

  alias Membrane.{AV1, Buffer, KeyframeRequestEvent, RawVideo}
  alias Membrane.AV1.Encoder.Native

  def_input_pad :input,
    accepted_format: %Membrane.RawVideo{pixel_format: :I420, aligned: true}

  def_output_pad :output,
    accepted_format: AV1

  @fallback_framerate {30, 1}

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
                - CQP (Constant Quantization Parameter) - The same quantization parameter (which controls
                the compression level) is used for each frame. Higher values mean higher compression.
                - CRF (Constant Rate Factor) - Quantization parameter is adjusted for each frame to maintain
                a certain level of perceived quality. Higher values mean higher compression.
                - CBR (Constant Bit Rate) - Provided bitrate is maintained for each frame
                  for the whole stream. Suitable for live-streaming. `:prediction_structure` option
                  MUST be set to :low_delay.
                - VBR (Variable Bit Rate) - The encoder will aim to produce a stream with the
                  average bitrate of the provided value, varying the size of the output depending on
                  the complexity of the input. This mode prohibits forcing keyframes.
                """
              ],
              prediction_structure: [
                spec: prediction_structure(),
                default: :random_access,
                description: """
                Prediction structure used when encoding the stream:
                - `:all_intra` - Every frame is an intra frame.
                - `:low_delay` - Frames can only reference previous frames. Additionally no frames
                  are buffered, each input frame will result in an encoded output frame. Forced for
                  real time coding.
                - `:random_access` - B-frames are allowed.
                """
              ],
              intra_refresh_type: [
                spec: intra_refresh_type(),
                default: :closed_gop,
                description: """
                Determines what type of intra-frame is inserted at the boundaries of GOPs:
                - `:closed_gop` - the encoder produces a keyframe (IDR), which is fully
                  independent and a decoder can start decoding from this point in the stream.
                - `:open_gop` - the encoder produces an intra-only frame (CRA), which can reference
                  previous frames, and therefore is not fully independent, but has lower overhead.

                To allow the encoder to force keyframes, this option has to be set to `:closed_gop`,
                because intra refresh points have to be true keyframes, not just intra-only frames,
                in order to be independently decodable. This can lead to slightly worse performance.
                Forcing keyframes is not allowed when `:rate_control` option is in VBR mode, even if this option is
                set to `:closed_gop`.
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
                Used by the encoder for computations regarding bitrate and intra periods. If not
                provided here, value from stream format is assumed. If not present there too, a default
                fallback value of #{inspect(@fallback_framerate)} is assumed.
                """
              ],
              config_parameters: [
                spec: %{String.t() => String.t()},
                default: %{},
                description: """
                Parameters accepted by SVT-AV1 encoder. They override parameters set by other
                options. For possible values refer to
                https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/Parameters.md
                ("Command line" column, without leading dashes).
                """
              ]

  @level_to_config_param %{
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

  @type prediction_structure :: :all_intra | :low_delay | :random_access

  @type rate_control ::
          {:cqp | :crf, quantization_parameter :: 0..63}
          | {:cbr | :vbr, target_bitrate :: non_neg_integer()}

  @type intra_refresh_type :: :closed_gop | :open_gop

  defmodule Framerate do
    @moduledoc false

    @type t :: %__MODULE__{
            numerator: non_neg_integer(),
            denominator: pos_integer()
          }

    @enforce_keys [:numerator, :denominator]

    defstruct @enforce_keys
  end

  defmodule EncodedFrame do
    @moduledoc false

    @type t :: %__MODULE__{
            payload: binary(),
            pts: integer(),
            dts: integer(),
            is_keyframe: boolean()
          }
    @enforce_keys [:payload, :pts, :dts, :is_keyframe]

    defstruct @enforce_keys
  end

  defmodule RawFrame do
    @moduledoc false
    alias Membrane.AV1.Encoder.Framerate

    @type t :: %__MODULE__{
            payload: binary(),
            pts: integer(),
            width: non_neg_integer(),
            height: non_neg_integer(),
            framerate: Framerate.t()
          }
    @enforce_keys [:payload, :pts, :width, :height, :framerate]

    defstruct @enforce_keys
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
            intra_refresh_type: AV1.Encoder.intra_refresh_type(),
            level: AV1.level(),
            options_framerate: AV1.framerate(),
            config_parameters: %{String.t() => String.t()},
            encoder_ref: reference() | nil,
            current_stream_format: RawVideo.t() | nil,
            force_next_keyframe: boolean()
          }

    @enforce_keys [
      :encoder_mode,
      :real_time_coding,
      :rate_control,
      :prediction_structure,
      :intra_refresh_type,
      :level,
      :options_framerate,
      :config_parameters
    ]
    defstruct @enforce_keys ++
                [
                  encoder_ref: nil,
                  current_stream_format: nil,
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
       intra_refresh_type: opts.intra_refresh_type,
       level: opts.level,
       options_framerate: opts.framerate,
       config_parameters: opts.config_parameters
     }}
  end

  @impl true
  def handle_stream_format(:input, stream_format, _ctx, %State{encoder_ref: nil} = state) do
    %RawVideo{framerate: {framerate_num, framerate_denom}} =
      stream_format =
      resolve_framerate(stream_format, state.options_framerate)

    level_config_param = translate_level(state.level)
    rate_control_config_params = translate_rate_control(state.rate_control)

    intra_refresh_type_config_param =
      case state.intra_refresh_type do
        :closed_gop -> "2"
        :open_gop -> "1"
      end

    internal_config_parameters_list =
      [
        {"preset", Integer.to_string(state.encoder_mode)},
        {"rtc", if(state.real_time_coding, do: "1", else: "0")},
        {"irefresh-type", intra_refresh_type_config_param},
        {"level", Integer.to_string(level_config_param)}
        | rate_control_config_params
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
        %Framerate{numerator: framerate_num, denominator: framerate_denom},
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

    {[stream_format: {:output, output_stream_format}],
     %State{state | encoder_ref: encoder_ref, current_stream_format: stream_format}}
  end

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
        %State{state | current_stream_format: new_input_stream_format}
      }
    else
      {[], state}
    end
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, %State{} = state) do
    {framerate_num, framerate_denom} = state.current_stream_format.framerate

    raw_frame = %RawFrame{
      payload: buffer.payload,
      pts: buffer.pts,
      width: state.current_stream_format.width,
      height: state.current_stream_format.height,
      framerate: %Framerate{numerator: framerate_num, denominator: framerate_denom}
    }

    {:ok, encoded_frames} =
      Native.encode_frame(
        raw_frame,
        state.force_next_keyframe,
        state.encoder_ref
      )

    buffers = get_buffers_from_frames(encoded_frames)

    {
      [buffer: {:output, buffers}],
      %State{state | force_next_keyframe: false}
    }
  end

  @impl true
  def handle_event(:output, %KeyframeRequestEvent{}, _ctx, %State{} = state) do
    cond do
      state.intra_refresh_type == :open_gop ->
        Membrane.Logger.warning(
          ":intra_refresh_type option does not allow forcing keyframes when set to `:open_gop`."
        )

        {[], state}

      match?({:vbr, _tbr}, state.rate_control) ->
        Membrane.Logger.warning(
          "VBR rate control does not allow forcing keyframes, see `:rate_control` option for details."
        )

      true ->
        {[], %State{state | force_next_keyframe: true}}
    end
  end

  def handle_event(pad, event, ctx, state) do
    super(pad, event, ctx, state)
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    {:ok, encoded_frames} = Native.flush(state.encoder_ref)
    buffers = get_buffers_from_frames(encoded_frames)
    {[buffer: {:output, buffers}, end_of_stream: :output], state}
  end

  @spec translate_level(Membrane.AV1.level() | :auto) :: non_neg_integer()
  defp translate_level(level) do
    case Map.get(@level_to_config_param, level) do
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
          Membrane.Logger.warning(
            "Framerate provided neither with stream format or options, using fallback value #{inspect(@fallback_framerate)}"
          )

          @fallback_framerate

        {nil, options_framerate} ->
          options_framerate

        {stream_format_framerate, nil} ->
          stream_format_framerate

        {_stream_format_framerate, options_framerate} ->
          Membrane.Logger.warning(
            "Framerate provided both with stream format and options, assuming value from options: #{inspect(options_framerate)}"
          )

          options_framerate
      end

    %RawVideo{stream_format | framerate: resolved_framerate}
  end

  @spec get_buffers_from_frames([EncodedFrame.t()]) :: [Buffer.t()]
  defp get_buffers_from_frames(encoded_frames) do
    Enum.map(encoded_frames, fn frame ->
      %Buffer{
        payload: frame.payload,
        pts: Membrane.Time.nanoseconds(frame.pts),
        dts: Membrane.Time.nanoseconds(frame.dts),
        metadata: %{av1: %{is_keyframe: frame.is_keyframe}}
      }
    end)
  end
end
