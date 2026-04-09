defmodule Membrane.VPx.BundlexProject do
  use Bundlex.Project

  def project() do
    [
      natives: natives()
    ]
  end

  defp natives() do
    [
      av1_encoder: [
        interface: :nif,
        sources: ["av1_encoder.c"],
        os_deps: [
          "svt-av1": [
            {:precompiled,
             Membrane.PrecompiledDependencyProvider.get_dependency_url(:"svt-av1",
               version: "4.1.0"
             ), "SvtAv1Enc"},
            {:pkg_config, "SvtAv1Enc"}
          ]
        ],
        preprocessor: Unifex
      ]
    ]
  end
end
