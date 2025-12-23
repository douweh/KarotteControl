defmodule KarotteControl.Dokku.SSHCredential do
  use Ecto.Schema
  import Ecto.Changeset

  schema "droplet_ssh_credentials" do
    field :droplet_id, :string
    field :droplet_name, :string
    field :ssh_user, :string, default: "root"
    field :ssh_private_key, :binary
    field :ssh_port, :integer, default: 22

    timestamps(type: :utc_datetime)
  end

  def changeset(credential, attrs) do
    credential
    |> cast(attrs, [:droplet_id, :droplet_name, :ssh_user, :ssh_private_key, :ssh_port])
    |> validate_required([:droplet_id, :ssh_private_key])
    |> unique_constraint(:droplet_id)
  end
end
