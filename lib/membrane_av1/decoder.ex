defmodule Membrane.AV1.Decoder do
  @moduledoc """
  AV1 Decoder based on dav1d library.
  """
  use Membrane.Filter

  require Membrane.Logger

  alias Membrane.{AV1, RawVideo}
  alias Membrane.AV1.Decoder.Native

  def_input_pad :input,
    accepted_format: AV1

  def_output_pad :output,
    accepted_format: %RawVideo{pixel_format: :I420, aligned: true}

  defmodule State do
    @type t :: %__MODULE__{decoder_ref: reference()}

    @enforce_keys [:decoder_ref]
    defstruct @enforce_keys ++ []
  end

  @impl true
  def handle_init(opts, _ctx) do
    {:ok, decoder_ref} = Native.create()
    {[], %State{decoder_ref: decoder_ref}}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
  end
end
