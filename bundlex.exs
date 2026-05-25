defmodule Membrane.AV1.BundlexProject do
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
      ],
      av1_decoder: [
        interface: :nif,
        sources: ["av1_decoder.c"],
        os_deps: [
          dav1d: [
            {:precompiled,
             Membrane.PrecompiledDependencyProvider.get_dependency_url(:dav1d, version: "1.5.3")},
            {:pkg_config, "dav1d"}
          ]
        ],
        preprocessor: Unifex
      ]
    ]
  end
end
