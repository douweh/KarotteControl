defmodule KarotteControl.Dokku.Credentials do
  @moduledoc """
  Context for managing SSH credentials for Dokku droplets.
  """

  import Ecto.Query
  alias KarotteControl.Repo
  alias KarotteControl.Dokku.SSHCredential

  def get_by_droplet_id(droplet_id) do
    Repo.get_by(SSHCredential, droplet_id: to_string(droplet_id))
  end

  def list_all do
    Repo.all(SSHCredential)
  end

  def create(attrs) do
    %SSHCredential{}
    |> SSHCredential.changeset(attrs)
    |> Repo.insert()
  end

  def update(%SSHCredential{} = credential, attrs) do
    credential
    |> SSHCredential.changeset(attrs)
    |> Repo.update()
  end

  def delete(%SSHCredential{} = credential) do
    Repo.delete(credential)
  end

  def upsert(attrs) do
    droplet_id = to_string(attrs[:droplet_id] || attrs["droplet_id"])

    %SSHCredential{}
    |> SSHCredential.changeset(Map.put(attrs, :droplet_id, droplet_id))
    |> Repo.insert(
      on_conflict: {:replace, [:droplet_name, :ssh_user, :ssh_private_key, :ssh_port, :updated_at]},
      conflict_target: :droplet_id
    )
  end

  def has_credentials?(droplet_id) do
    query = from c in SSHCredential, where: c.droplet_id == ^to_string(droplet_id)
    Repo.exists?(query)
  end
end
