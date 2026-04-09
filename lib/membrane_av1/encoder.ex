defmodule Membrane.AV1.Encoder do
  defmodule ConfigParameter do
    @moduledoc false
    @enforce_keys [:key, :value]
    defstruct @enforce_keys
  end
end
