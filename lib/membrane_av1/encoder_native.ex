defmodule Membrane.AV1.Encoder.Native do
  @moduledoc false
  use Unifex.Loader

  # @spec create!(
  #         non_neg_integer(),
  #         non_neg_integer(),
  #         non_neg_integer(),
  #         pos_integer(),
  #         [Membrane.AV1.Encoder.]
  #       ) :: reference()
  # def create!(
  #       width,
  #       height,
  #       frame_rate_numerator,
  #       frame_rate_denominator,
  #       config_parameters
  #     ) do
  #   case create(
  #          width,
  #          height,
  #          frame_rate_numerator,
  #          frame_rate_denominator,
  #          config_parameters
  #        ) do
  #     {:ok, encoder_ref} -> encoder_ref
  #     {:error, reason} -> raise "Failed to create native encoder: #{inspect(reason)}"
  #   end
  # end
end
