defmodule NervesHubLinkAVM.Verifier.SHA256 do
  @moduledoc """
  Default verifier — checks firmware integrity via SHA256 hash.

  Skips verification when the expected hash is empty (allows unsigned updates).
  """

  @behaviour NervesHubLinkAVM.Verifier

  @impl true
  def init(expected) do
    {:ok, %{ctx: :crypto.hash_init(:sha256), expected: expected}}
  end

  @impl true
  def update(data, state) do
    {:ok, %{state | ctx: :crypto.hash_update(state.ctx, data)}}
  end

  @impl true
  def finish(%{expected: ""}), do: :ok

  def finish(%{ctx: ctx, expected: expected}) do
    computed =
      :crypto.hash_final(ctx)
      |> :binary.encode_hex(:lowercase)

    if computed == expected, do: :ok, else: {:error, :sha256_mismatch}
  end
end
