defmodule KarotteControl.Dokku.ImagePoller do
  @moduledoc """
  GenServer that periodically checks for new Docker images in the registry
  and triggers auto-deploy for linked Dokku apps.
  """

  use GenServer
  require Logger

  alias KarotteControl.Dokku.{Deployments, SSH}
  alias KarotteControl.DigitalOcean.Registry
  alias Phoenix.PubSub

  # Poll every 10 seconds (for debugging - change to 60 in production)
  @poll_interval :timer.seconds(10)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Manually trigger a check for all auto-deploy enabled apps.
  """
  def check_now do
    GenServer.cast(__MODULE__, :check_now)
  end

  @doc """
  Manually trigger a deploy for a specific app.
  """
  def deploy_app(droplet_id, app_name) do
    GenServer.cast(__MODULE__, {:deploy_app, droplet_id, app_name})
  end

  # Callbacks

  @impl true
  def init(_opts) do
    # Schedule first check after a short delay to let the app start up
    Process.send_after(self(), :poll, :timer.seconds(10))
    {:ok, %{}}
  end

  @impl true
  def handle_info(:poll, state) do
    check_for_updates()
    schedule_poll()
    {:noreply, state}
  end

  @impl true
  def handle_cast(:check_now, state) do
    check_for_updates()
    {:noreply, state}
  end

  def handle_cast({:deploy_app, droplet_id, app_name}, state) do
    case Deployments.get(droplet_id, app_name) do
      nil ->
        Logger.warning("No deployment config found for #{app_name} on droplet #{droplet_id}")

      deployment ->
        deploy_if_needed(deployment, true)
    end

    {:noreply, state}
  end

  # Private functions

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval)
  end

  defp check_for_updates do
    deployments = Deployments.list_auto_deploy_enabled()
    Logger.info("[ImagePoller] Checking #{length(deployments)} auto-deploy enabled app(s)")

    Enum.each(deployments, fn deployment ->
      Logger.debug("[ImagePoller] Checking #{deployment.app_name} (#{deployment.repository_name}:#{deployment.tag})")
      deploy_if_needed(deployment, false)
    end)
  end

  defp deploy_if_needed(deployment, force) do
    with {:ok, current_digest} <- get_current_digest(deployment) do
      if force or digest_changed?(deployment, current_digest) do
        Logger.info("[ImagePoller] New digest detected for #{deployment.app_name}: #{String.slice(current_digest, 0, 20)}...")
        Logger.info("[ImagePoller] Deploying #{deployment.app_name} on droplet #{deployment.droplet_id}")
        do_deploy(deployment, current_digest)
      else
        Logger.debug("[ImagePoller] #{deployment.app_name} is up to date (digest: #{String.slice(current_digest || "", 0, 20)}...)")
      end
    else
      {:error, reason} ->
        Logger.error("[ImagePoller] Failed to get digest for #{deployment.repository_name}:#{deployment.tag}: #{inspect(reason)}")
    end
  end

  defp get_current_digest(deployment) do
    with {:ok, tags} <- Registry.list_tags(deployment.registry_name, deployment.repository_name) do
      case Enum.find(tags, &(&1["tag"] == deployment.tag)) do
        nil -> {:error, :tag_not_found}
        tag -> {:ok, tag["manifest_digest"]}
      end
    end
  end

  defp digest_changed?(deployment, current_digest) do
    deployment.last_digest != current_digest
  end

  defp do_deploy(deployment, digest) do
    # Use digest instead of tag to force Dokku to pull the new image
    # (Dokku's git:from-image skips deploy if the tag name is unchanged)
    image_url = build_image_url_with_digest(deployment, digest)

    # Broadcast that deployment is starting
    broadcast_deployment(deployment, :deploying, nil, "Deploying...")

    case SSH.deploy_from_image(deployment.droplet_id, deployment.app_name, image_url) do
      {:ok, output} ->
        Logger.info("[ImagePoller] Successfully deployed #{deployment.app_name}")

        # Run post-deploy command if configured (e.g., migrations)
        post_deploy_output = run_post_deploy(deployment)

        # Combine outputs
        full_output = case post_deploy_output do
          {:ok, post_output} -> output <> "\n\n--- Post-deploy command ---\n" <> post_output
          {:error, post_error} ->
            error_str = if is_binary(post_error), do: post_error, else: inspect(post_error)
            output <> "\n\n--- Post-deploy command FAILED ---\n" <> error_str
          nil -> output
        end

        {:ok, updated} = Deployments.update_digest(deployment, digest, "success")
        broadcast_deployment(updated, :deployed, nil, full_output)

      {:error, reason} when is_binary(reason) ->
        # Check if this is a "no changes" message - not actually an error
        if String.contains?(reason, "No changes detected") do
          Logger.info("[ImagePoller] #{deployment.app_name} already up to date, saving digest")
          {:ok, updated} = Deployments.update_digest(deployment, digest, "success")
          broadcast_deployment(updated, :deployed, nil, "No changes detected - image already deployed")
        else
          Logger.error("[ImagePoller] Failed to deploy #{deployment.app_name}: #{reason}")
          {:ok, updated} = Deployments.update_digest(deployment, deployment.last_digest, "failed")
          broadcast_deployment(updated, :deploy_failed, reason, reason)
        end

      {:error, reason} ->
        Logger.error("[ImagePoller] Failed to deploy #{deployment.app_name}: #{inspect(reason)}")
        {:ok, updated} = Deployments.update_digest(deployment, deployment.last_digest, "failed")
        broadcast_deployment(updated, :deploy_failed, reason, inspect(reason))
    end
  end

  defp run_post_deploy(%{post_deploy_command: nil}), do: nil
  defp run_post_deploy(%{post_deploy_command: ""}), do: nil

  defp run_post_deploy(deployment) do
    Logger.info("[ImagePoller] Running post-deploy command for #{deployment.app_name}: #{deployment.post_deploy_command}")

    case SSH.run_command(deployment.droplet_id, deployment.app_name, deployment.post_deploy_command) do
      {:ok, output} ->
        Logger.info("[ImagePoller] Post-deploy command completed for #{deployment.app_name}")
        {:ok, output}

      {:error, reason} ->
        Logger.error("[ImagePoller] Post-deploy command failed for #{deployment.app_name}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Use digest (@sha256:...) instead of tag to force Dokku to recognize image changes
  # See: https://github.com/dokku/dokku/issues/6847
  defp build_image_url_with_digest(deployment, digest) do
    "registry.digitalocean.com/#{deployment.registry_name}/#{deployment.repository_name}@#{digest}"
  end

  defp broadcast_deployment(deployment, status, error, output) do
    topic = "dokku_app:#{deployment.droplet_id}:#{deployment.app_name}"

    PubSub.broadcast(
      KarotteControl.PubSub,
      topic,
      {:deployment_update, %{deployment: deployment, status: status, error: error, output: output}}
    )
  end
end
