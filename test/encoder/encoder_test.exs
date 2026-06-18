defmodule Membrane.AV1.EncoderTest do
  use ExUnit.Case, async: true

  import Membrane.Testing.Assertions
  import Membrane.ChildrenSpec

  alias Membrane.{AV1, Testing}

  @fixtures_dir "test/fixtures"
  @input "input_yuv420p_1080_720.raw"

  describe "Encoder encodes correctly" do
    @describetag :tmp_dir

    test "for default settings", %{tmp_dir: tmp_dir} do
      perform_encoder_test(tmp_dir, @input, "ref_default.ivf", %AV1.Encoder{})
    end

    test "for low-delay", %{tmp_dir: tmp_dir} do
      perform_encoder_test(tmp_dir, @input, "ref_low_delay.ivf", %AV1.Encoder{
        prediction_structure: :low_delay
      })
    end
  end

  defp perform_encoder_test(tmp_dir, input_file, ref_file, encoder_struct) do
    input_path = Path.join(@fixtures_dir, input_file)

    ref_path = Path.join(@fixtures_dir, ref_file)
    output_path = Path.join(tmp_dir, "output.ivf")

    pid =
      Testing.Pipeline.start_link_supervised!(
        spec:
          child(:source, %Membrane.File.Source{location: input_path})
          |> child(:parser, %Membrane.RawVideo.Parser{
            pixel_format: :I420,
            width: 1080,
            height: 720,
            framerate: {30, 1}
          })
          |> child(:encoder, encoder_struct)
          |> child(:serializer, Membrane.IVF.Serializer)
          |> child(:sink, %Membrane.File.Sink{location: output_path})
      )

    assert_end_of_stream(pid, :sink, :input, 100_000)

    assert File.read!(ref_path) == File.read!(output_path)

    Testing.Pipeline.terminate(pid)
  end
end
