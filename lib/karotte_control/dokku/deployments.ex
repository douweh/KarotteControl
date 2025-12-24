defmodule KarotteControl.Dokku.Deployments do
  @moduledoc """
  Context for managing Dokku app deployments and their linked container registry images.
  """

  import Ecto.Query
  alias KarotteControl.Repo
  alias KarotteControl.Dokku.AppDeployment

  @doc """
  Gets a deployment by droplet_id and app_name.
  """
  def get(droplet_id, app_name) do
    Repo.get_by(AppDeployment, droplet_id: droplet_id, app_name: app_name)
  end

  @doc """
  Gets or creates a deployment record for a Dokku app.
  """
  def get_or_create(droplet_id, app_name) do
    case get(droplet_id, app_name) do
      nil ->
        %AppDeployment{}
        |> AppDeployment.changeset(%{droplet_id: droplet_id, app_name: app_name})
        |> Repo.insert()

      deployment ->
        {:ok, deployment}
    end
  end

  @doc """
  Links a Dokku app to a container registry image for auto-deploy.
  Options:
    - tag: image tag (default: "latest")
    - auto_deploy: enable auto-deploy (default: true)
    - post_deploy_command: command to run after deploy (e.g., "./bin/migrate")
  """
  def link_image(droplet_id, app_name, registry_name, repository_name, opts \\ []) do
    tag = Keyword.get(opts, :tag, "latest")
    auto_deploy = Keyword.get(opts, :auto_deploy, true)
    post_deploy_command = Keyword.get(opts, :post_deploy_command)

    with {:ok, deployment} <- get_or_create(droplet_id, app_name) do
      deployment
      |> AppDeployment.link_image_changeset(%{
        registry_name: registry_name,
        repository_name: repository_name,
        tag: tag,
        auto_deploy: auto_deploy,
        post_deploy_command: post_deploy_command
      })
      |> Repo.update()
    end
  end

  @doc """
  Unlinks a Dokku app from its container registry image.
  """
  def unlink_image(droplet_id, app_name) do
    case get(droplet_id, app_name) do
      nil ->
        {:ok, nil}

      deployment ->
        deployment
        |> AppDeployment.link_image_changeset(%{
          registry_name: nil,
          repository_name: nil,
          tag: nil,
          auto_deploy: false,
          post_deploy_command: nil
        })
        |> Repo.update()
    end
  end

  @doc """
  Updates the last known digest after a successful deployment.
  """
  def update_digest(deployment, digest, status \\ "success") do
    deployment
    |> AppDeployment.update_digest_changeset(%{
      last_digest: digest,
      last_deployed_at: DateTime.utc_now(),
      last_deploy_status: status
    })
    |> Repo.update()
  end

  @doc """
  Lists all deployments with auto_deploy enabled.
  """
  def list_auto_deploy_enabled do
    AppDeployment
    |> where([d], d.auto_deploy == true)
    |> where([d], not is_nil(d.registry_name))
    |> where([d], not is_nil(d.repository_name))
    |> Repo.all()
  end

  @doc """
  Toggles auto-deploy for a deployment.
  """
  def toggle_auto_deploy(droplet_id, app_name) do
    case get(droplet_id, app_name) do
      nil ->
        {:error, :not_found}

      deployment ->
        deployment
        |> AppDeployment.changeset(%{auto_deploy: !deployment.auto_deploy})
        |> Repo.update()
    end
  end
end
