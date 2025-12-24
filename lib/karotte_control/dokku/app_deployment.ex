defmodule KarotteControl.Dokku.AppDeployment do
  @moduledoc """
  Schema for tracking Dokku app deployments and their linked container registry images.
  Used for auto-deploy when a new image is pushed to the registry.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "dokku_app_deployments" do
    field :droplet_id, :string
    field :app_name, :string

    # Registry image source
    field :registry_name, :string
    field :repository_name, :string
    field :tag, :string, default: "latest"

    # Last known digest for auto-deploy detection
    field :last_digest, :string

    # Auto-deploy settings
    field :auto_deploy, :boolean, default: false

    # Post-deploy command (e.g., migrations)
    field :post_deploy_command, :string

    # Last deployment info
    field :last_deployed_at, :utc_datetime
    field :last_deploy_status, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(deployment, attrs) do
    deployment
    |> cast(attrs, [
      :droplet_id,
      :app_name,
      :registry_name,
      :repository_name,
      :tag,
      :last_digest,
      :auto_deploy,
      :post_deploy_command,
      :last_deployed_at,
      :last_deploy_status
    ])
    |> validate_required([:droplet_id, :app_name])
    |> unique_constraint([:droplet_id, :app_name])
  end

  def link_image_changeset(deployment, attrs) do
    deployment
    |> cast(attrs, [:registry_name, :repository_name, :tag, :auto_deploy, :post_deploy_command])
    |> validate_required([:registry_name, :repository_name])
  end

  def update_digest_changeset(deployment, attrs) do
    deployment
    |> cast(attrs, [:last_digest, :last_deployed_at, :last_deploy_status])
  end
end
