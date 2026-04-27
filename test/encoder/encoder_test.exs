defmodule Membrane.AV1.EncoderTest do
  use ExUnit.Case, async: true

  import Membrane.Testing.Assertions
  import Membrane.ChildrenSpec

  @fixtures_dir "test/fixtures"

  @input "input_yuv420p_1080_720.raw"
  @ref "ref.ivf"

  @tag :tmp_dir
  test "Encoder encodes correctly", %{tmp_dir: tmp_dir} do
    input_path = Path.join(@fixtures_dir, @input)

    ref_path = Path.join(@fixtures_dir, @ref)
    output_path = Path.join(tmp_dir, "out.ivf")

    pid =
      Membrane.Testing.Pipeline.start_link_supervised!(
        spec:
          child(:source, %Membrane.File.Source{location: input_path})
          |> child(:parser, %Membrane.RawVideo.Parser{
            pixel_format: :I420,
            width: 1080,
            height: 720,
            framerate: {30, 1}
          })
          |> child(:encoder, %Membrane.AV1.Encoder{encoder_mode: 7})
          |> child(:serializer, %Membrane.IVF.Serializer{
            timebase: {1, 30}
          })
          |> child(:sink, %Membrane.File.Sink{location: output_path})
      )

    assert_end_of_stream(pid, :sink, :input, 100_000)

    assert File.read!(ref_path) == File.read!(output_path)

    Membrane.Testing.Pipeline.terminate(pid)
  end
end
