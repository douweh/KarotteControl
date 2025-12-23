defmodule KarotteControl.Dokku.KeyGenerator do
  @moduledoc """
  Generates SSH key pairs for Dokku droplet access.
  """

  @doc """
  Generates an ED25519 SSH key pair.
  Returns {:ok, %{private_key: String.t(), public_key: String.t()}} or {:error, reason}
  """
  def generate_key_pair do
    # Generate ED25519 key pair using ssh-keygen
    temp_dir = System.tmp_dir!()
    key_path = Path.join(temp_dir, "dokku_key_#{:erlang.unique_integer([:positive])}")

    try do
      # Generate key with no passphrase
      {_output, 0} =
        System.cmd("ssh-keygen", [
          "-t", "ed25519",
          "-f", key_path,
          "-N", "",  # No passphrase
          "-C", "karotte-control-generated"
        ], stderr_to_stdout: true)

      private_key = File.read!(key_path)
      public_key = File.read!(key_path <> ".pub")

      {:ok, %{private_key: private_key, public_key: String.trim(public_key)}}
    rescue
      e -> {:error, Exception.message(e)}
    after
      # Clean up temporary files
      File.rm(key_path)
      File.rm(key_path <> ".pub")
    end
  end
end
