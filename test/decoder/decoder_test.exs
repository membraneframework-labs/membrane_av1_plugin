defmodule Membrane.AV1.DecoderTest do
  use ExUnit.Case, async: true

  import Membrane.Testing.Assertions
  import Membrane.ChildrenSpec

  alias Membrane.{AV1, Testing}

  @fixtures_dir "test/fixtures"
  @input "input.ivf"

  describe "Decoder decodes correctly" do
    @describetag :tmp_dir

    test "for default settings", %{tmp_dir: tmp_dir} do
      perform_decoder_test(tmp_dir, @input, "ref_yuv420p_1080_720_default.raw", %AV1.Decoder{})
    end
  end

  defp perform_decoder_test(tmp_dir, input_file, ref_file, decoder_struct) do
    input_path = Path.join(@fixtures_dir, input_file)

    ref_path = Path.join(@fixtures_dir, ref_file)
    output_path = Path.join(tmp_dir, "output.raw")

    pid =
      Testing.Pipeline.start_link_supervised!(
        spec:
          child(:source, %Membrane.File.Source{location: input_path})
          |> child(:serializer, Membrane.IVF.Deserializer)
          |> child(:decoder, decoder_struct)
          |> child(:sink, %Membrane.File.Sink{location: output_path})
      )

    assert_end_of_stream(pid, :sink, :input, 100_000)

    assert File.read!(ref_path) == File.read!(output_path)

    Testing.Pipeline.terminate(pid)
  end
end
