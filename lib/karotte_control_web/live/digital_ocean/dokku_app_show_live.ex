defmodule KarotteControlWeb.DigitalOcean.DokkuAppShowLive do
  use KarotteControlWeb, :live_view

  alias KarotteControl.DigitalOcean.{Droplets, Registry}
  alias KarotteControl.Dokku.{Deployments, SSH}

  @impl true
  def mount(%{"droplet_id" => droplet_id, "app_name" => app_name}, _session, socket) do
    socket =
      socket
      |> assign(:droplet_id, droplet_id)
      |> assign(:app_name, app_name)
      |> assign(:droplet, nil)
      |> assign(:app_info, nil)
      |> assign(:domains, [])
      |> assign(:env_vars, nil)
      |> assign(:loading, true)
      |> assign(:error, nil)
      |> assign(:action_loading, false)
      # Env var modal
      |> assign(:show_env_modal, false)
      |> assign(:editing_env, nil)
      |> assign(:env_key, "")
      |> assign(:env_value, "")
      |> assign(:saving, false)
      # Track if env vars changed and need restart
      |> assign(:env_changed, false)
      # Domain modal
      |> assign(:show_domain_modal, false)
      |> assign(:new_domain, "")
      # Deployment config
      |> assign(:deployment, nil)
      |> assign(:show_deploy_modal, false)
      |> assign(:repositories, [])
      |> assign(:tags, [])
      |> assign(:selected_repo, nil)
      |> assign(:selected_tag, "latest")
      |> assign(:deploying, false)
      # SSH log
      |> assign(:ssh_logs, [])
      # Streaming output accumulator
      |> assign(:streaming_output, "")

    if connected?(socket) do
      send(self(), :load_data)
      # Subscribe to deployment updates from ImagePoller
      Phoenix.PubSub.subscribe(KarotteControl.PubSub, "dokku_app:#{droplet_id}:#{app_name}")
    end

    {:ok, socket}
  end

  @impl true
  def handle_info({:env_set_result, key, {:ok, output}}, socket) do
    {:noreply, add_ssh_log(socket, :success, "config:set #{key}", output)}
  end

  def handle_info({:env_set_result, key, {:error, reason}}, socket) do
    output = if is_binary(reason), do: reason, else: inspect(reason)

    {:noreply,
     socket
     |> add_ssh_log(:error, "config:set #{key}", output)
     |> put_flash(:error, "Failed to set #{key}")}
  end

  def handle_info({:env_unset_result, key, {:ok, output}}, socket) do
    {:noreply, add_ssh_log(socket, :success, "config:unset #{key}", output)}
  end

  def handle_info({:env_unset_result, key, {:error, reason}}, socket) do
    output = if is_binary(reason), do: reason, else: inspect(reason)

    {:noreply,
     socket
     |> add_ssh_log(:error, "config:unset #{key}", output)
     |> put_flash(:error, "Failed to unset #{key}")}
  end

  def handle_info({:domain_add_result, domain, {:ok, output}}, socket) do
    {:noreply, add_ssh_log(socket, :success, "domains:add #{domain}", output)}
  end

  def handle_info({:domain_add_result, domain, {:error, reason}}, socket) do
    output = if is_binary(reason), do: reason, else: inspect(reason)
    # Remove from optimistic UI on failure
    updated_domains = Enum.reject(socket.assigns.domains, &(&1 == domain))

    {:noreply,
     socket
     |> assign(:domains, updated_domains)
     |> add_ssh_log(:error, "domains:add #{domain}", output)
     |> put_flash(:error, "Failed to add domain #{domain}")}
  end

  def handle_info({:domain_remove_result, domain, {:ok, output}}, socket) do
    {:noreply, add_ssh_log(socket, :success, "domains:remove #{domain}", output)}
  end

  def handle_info({:domain_remove_result, domain, {:error, reason}}, socket) do
    output = if is_binary(reason), do: reason, else: inspect(reason)
    # Re-add to UI on failure
    updated_domains = socket.assigns.domains ++ [domain]

    {:noreply,
     socket
     |> assign(:domains, updated_domains)
     |> add_ssh_log(:error, "domains:remove #{domain}", output)
     |> put_flash(:error, "Failed to remove domain #{domain}")}
  end

  def handle_info({:deploy_result, {:ok, output}}, socket) do
    send(self(), :load_data)

    # Finalize the log entry with success status
    socket =
      case socket.assigns.ssh_logs do
        [current | rest] ->
          updated_log = %{current | status: :success, output: output}
          assign(socket, :ssh_logs, [updated_log | rest])

        [] ->
          socket
      end

    # Update deployment digest
    if socket.assigns.deployment do
      Deployments.update_digest(socket.assigns.deployment, nil, "success")
    end

    {:noreply,
     socket
     |> assign(:deploying, false)
     |> assign(:streaming_output, "")
     |> put_flash(:info, "Deployment complete")}
  end

  def handle_info({:deploy_result, {:error, reason}}, socket) do
    output = if is_binary(reason), do: reason, else: inspect(reason)

    # Finalize the log entry with error status
    socket =
      case socket.assigns.ssh_logs do
        [current | rest] ->
          updated_log = %{current | status: :error, output: output}
          assign(socket, :ssh_logs, [updated_log | rest])

        [] ->
          socket
      end

    {:noreply,
     socket
     |> assign(:deploying, false)
     |> assign(:streaming_output, "")
     |> put_flash(:error, "Deployment failed")}
  end

  # Handle streaming SSH output chunks
  def handle_info({:ssh_output, chunk}, socket) do
    # Accumulate output and update the current log entry
    new_output = socket.assigns.streaming_output <> chunk
    socket = assign(socket, :streaming_output, new_output)

    # Update the most recent log entry with the new output
    case socket.assigns.ssh_logs do
      [current | rest] ->
        updated_log = %{current | output: new_output}
        {:noreply, assign(socket, :ssh_logs, [updated_log | rest])}

      [] ->
        {:noreply, socket}
    end
  end

  def handle_info({:restart_result, {:ok, output}}, socket) do
    send(self(), :load_data)

    # Finalize the log entry with success status
    socket =
      case socket.assigns.ssh_logs do
        [current | rest] ->
          updated_log = %{current | status: :success, output: output}
          assign(socket, :ssh_logs, [updated_log | rest])

        [] ->
          socket
      end

    {:noreply,
     socket
     |> assign(:action_loading, false)
     |> assign(:env_changed, false)
     |> assign(:streaming_output, "")
     |> put_flash(:info, "App restarted")}
  end

  def handle_info({:restart_result, {:error, reason}}, socket) do
    output = if is_binary(reason), do: reason, else: inspect(reason)

    # Finalize the log entry with error status
    socket =
      case socket.assigns.ssh_logs do
        [current | rest] ->
          updated_log = %{current | status: :error, output: output}
          assign(socket, :ssh_logs, [updated_log | rest])

        [] ->
          socket
      end

    {:noreply,
     socket
     |> assign(:action_loading, false)
     |> assign(:streaming_output, "")
     |> put_flash(:error, "Failed to restart app")}
  end

  @impl true
  def handle_info(:load_data, socket) do
    droplet_id = socket.assigns.droplet_id
    app_name = socket.assigns.app_name

    socket =
      with {:ok, droplet} <- Droplets.get(droplet_id),
           {:ok, app_info} <- SSH.app_info(droplet_id, app_name),
           {:ok, domains} <- SSH.list_domains(droplet_id, app_name),
           {:ok, env_vars} <- SSH.get_env(droplet_id, app_name) do
        # Also load deployment config (may be nil)
        deployment = Deployments.get(droplet_id, app_name)

        socket
        |> assign(:page_title, "#{app_name} on #{droplet["name"]}")
        |> assign(:droplet, droplet)
        |> assign(:app_info, app_info)
        |> assign(:domains, domains)
        |> assign(:env_vars, env_vars)
        |> assign(:deployment, deployment)
        |> assign(:loading, false)
      else
        {:error, reason} ->
          socket
          |> assign(:error, inspect(reason))
          |> assign(:loading, false)
      end

    {:noreply, socket}
  end

  # Handle deployment updates from ImagePoller
  def handle_info({:deployment_update, %{deployment: deployment, status: status, error: error, output: output}}, socket) do
    socket =
      case status do
        :deploying ->
          # Add a log entry for the auto-deploy starting
          image_url = "registry.digitalocean.com/#{deployment.registry_name}/#{deployment.repository_name}:#{deployment.tag}"
          log_entry = %{
            id: System.unique_integer([:positive]),
            timestamp: DateTime.utc_now(),
            status: :running,
            command: "[auto-deploy] git:from-image #{socket.assigns.app_name} #{image_url}",
            output: output || "Auto-deploy triggered by new image..."
          }
          logs = [log_entry | socket.assigns.ssh_logs] |> Enum.take(20)

          socket
          |> assign(:ssh_logs, logs)
          |> assign(:deploying, true)
          |> put_flash(:info, "Auto-deploy started - new image detected")

        :deployed ->
          # Reload data to get fresh app info
          send(self(), :load_data)

          # Update the log entry with success and full output
          socket =
            case socket.assigns.ssh_logs do
              [current | rest] when current.status == :running ->
                updated_log = %{current | status: :success, output: output || "Deployment completed successfully"}
                assign(socket, :ssh_logs, [updated_log | rest])
              _ ->
                socket
            end

          socket
          |> assign(:deployment, deployment)
          |> assign(:deploying, false)
          |> put_flash(:info, "Auto-deploy completed successfully")

        :deploy_failed ->
          error_msg = if is_binary(error), do: error, else: inspect(error)

          # Update the log entry with failure and full output
          socket =
            case socket.assigns.ssh_logs do
              [current | rest] when current.status == :running ->
                updated_log = %{current | status: :error, output: output || error_msg}
                assign(socket, :ssh_logs, [updated_log | rest])
              _ ->
                socket
            end

          socket
          |> assign(:deployment, deployment)
          |> assign(:deploying, false)
          |> put_flash(:error, "Auto-deploy failed: #{String.slice(error_msg, 0, 100)}")
      end

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex gap-6">
      <!-- Main content area -->
      <div class="flex-1 space-y-6 min-w-0">
        <div class="flex items-center gap-4">
          <button onclick="history.back()" class="btn btn-ghost btn-sm">
            <.icon name="hero-arrow-left" class="h-4 w-4" /> Back
          </button>
          <div>
            <h1 class="text-2xl font-bold">{@app_name}</h1>
            <%= if @droplet do %>
              <p class="text-base-content/60">Dokku app on {@droplet["name"]}</p>
            <% end %>
          </div>
        </div>

        <%= if @loading do %>
          <div class="flex justify-center py-12">
            <span class="loading loading-spinner loading-lg"></span>
          </div>
        <% end %>

        <%= if @error do %>
          <div role="alert" class="alert alert-error">
            <.icon name="hero-exclamation-circle" class="h-5 w-5" />
            <span>Error: {@error}</span>
          </div>
        <% end %>

        <%= if not @loading and is_nil(@error) do %>
          <!-- App Info Card -->
          <div class="card bg-base-100 shadow-md">
            <div class="card-body">
              <div class="flex justify-between items-center">
                <h2 class="card-title">
                  <.icon name="hero-information-circle" class="h-5 w-5" />
                  App Status
                </h2>
                <div class="flex gap-2">
                  <button
                    class="btn btn-success btn-sm"
                    phx-click="restart_app"
                    disabled={@action_loading}
                  >
                    <.icon name="hero-arrow-path" class="h-4 w-4" /> Restart
                  </button>
                </div>
              </div>
              <%= if @app_info do %>
                <div class="overflow-x-auto">
                  <table class="table table-sm">
                    <tbody>
                      <%= for {key, value} <- @app_info do %>
                        <tr>
                          <th class="font-mono text-xs">{key}</th>
                          <td class="font-mono text-xs">{value}</td>
                        </tr>
                      <% end %>
                    </tbody>
                  </table>
                </div>
              <% else %>
                <p class="text-base-content/60">No app info available</p>
              <% end %>
            </div>
          </div>

          <!-- Deployment Card -->
          <.deployment_card
            deployment={@deployment}
            deploying={@deploying}
            action_loading={@action_loading}
          />

          <!-- Environment Variables Card -->
          <.env_vars_card env_vars={@env_vars} env_changed={@env_changed} action_loading={@action_loading} />

          <!-- Domains Card -->
          <.domains_card domains={@domains} />
        <% end %>

        <.env_modal
          :if={@show_env_modal}
          key={@env_key}
          value={@env_value}
          editing={@editing_env}
          saving={@saving}
        />

        <.domain_modal
          :if={@show_domain_modal}
          domain={@new_domain}
          saving={@saving}
        />

        <.deploy_modal
          :if={@show_deploy_modal}
          repositories={@repositories}
          tags={@tags}
          selected_repo={@selected_repo}
          selected_tag={@selected_tag}
          deployment={@deployment}
          saving={@saving}
        />
      </div>

      <!-- Fixed SSH Log Panel on the right -->
      <.ssh_log_panel logs={@ssh_logs} />
    </div>
    """
  end

  defp ssh_log_panel(assigns) do
    ~H"""
    <div class="w-[40rem] flex-shrink-0 hidden xl:block">
      <div class="sticky top-6">
        <div class="card bg-base-100 shadow-md">
          <div class="card-body p-4">
            <div class="flex justify-between items-center mb-2">
              <h2 class="card-title text-base">
                <.icon name="hero-command-line" class="h-4 w-4" />
                SSH Log
                <%= if length(@logs) > 0 do %>
                  <span class="badge badge-sm">{length(@logs)}</span>
                <% end %>
              </h2>
              <%= if length(@logs) > 0 do %>
                <button phx-click="clear_ssh_log" class="btn btn-ghost btn-xs">
                  Clear
                </button>
              <% end %>
            </div>

            <div
              id="ssh-log-container"
              class="h-[calc(100vh-12rem)] overflow-y-auto border border-base-300 rounded-lg bg-base-200"
              phx-hook="ScrollToBottom"
            >
              <%= if length(@logs) > 0 do %>
                <%= for log <- Enum.reverse(@logs) do %>
                  <div class={[
                    "border-b border-base-300 last:border-b-0",
                    log.status == :error && "bg-error/10",
                    log.status == :running && "bg-info/10"
                  ]}>
                    <div class="px-3 py-2">
                      <div class="flex items-center gap-2 text-xs text-base-content/60">
                        <%= case log.status do %>
                          <% :success -> %>
                            <.icon name="hero-check-circle" class="h-3 w-3 text-success" />
                          <% :error -> %>
                            <.icon name="hero-x-circle" class="h-3 w-3 text-error" />
                          <% :running -> %>
                            <span class="loading loading-spinner loading-xs text-info"></span>
                        <% end %>
                        <span class="font-mono truncate">{log.command}</span>
                        <span class="ml-auto flex-shrink-0">{Calendar.strftime(log.timestamp, "%H:%M:%S")}</span>
                      </div>
                      <%= if log.output != "" do %>
                        <pre class="mt-1 text-xs font-mono text-base-content/80 whitespace-pre-wrap break-all">{String.trim(log.output)}</pre>
                      <% end %>
                    </div>
                  </div>
                <% end %>
              <% else %>
                <div class="flex items-center justify-center h-32 text-base-content/40 text-sm">
                  No commands yet
                </div>
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp domains_card(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-md">
      <div class="card-body">
        <div class="flex justify-between items-center">
          <h2 class="card-title">
            <.icon name="hero-globe-alt" class="h-5 w-5" />
            Domains
          </h2>
          <button class="btn btn-primary btn-sm" phx-click="open_domain_modal">
            <.icon name="hero-plus" class="h-4 w-4" /> Add Domain
          </button>
        </div>

        <%= if @domains != [] do %>
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Domain</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <%= for domain <- @domains do %>
                  <tr>
                    <td class="font-mono text-sm">
                      <a href={"https://#{domain}"} target="_blank" class="link link-primary">
                        {domain}
                      </a>
                    </td>
                    <td>
                      <button
                        class="btn btn-ghost btn-xs text-error"
                        phx-click="delete_domain"
                        phx-value-domain={domain}
                        data-confirm="Are you sure you want to remove this domain?"
                      >
                        <.icon name="hero-trash" class="h-3 w-3" />
                      </button>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        <% else %>
          <p class="text-base-content/60">No custom domains configured</p>
        <% end %>
      </div>
    </div>
    """
  end

  defp domain_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box">
        <h3 class="font-bold text-lg">Add Domain</h3>
        <form phx-submit="add_domain" phx-change="update_domain_form" class="space-y-4 mt-4">
          <div class="form-control">
            <label class="label">
              <span class="label-text">Domain</span>
            </label>
            <input
              type="text"
              name="domain"
              value={@domain}
              class="input input-bordered"
              placeholder="app.example.com"
              required
            />
            <label class="label">
              <span class="label-text-alt">Enter the full domain name (e.g., app.example.com)</span>
            </label>
          </div>

          <div class="modal-action">
            <button type="button" class="btn" phx-click="close_domain_modal">Cancel</button>
            <button type="submit" class="btn btn-primary" disabled={@saving}>
              <%= if @saving do %>
                <span class="loading loading-spinner loading-sm"></span>
              <% else %>
                Add Domain
              <% end %>
            </button>
          </div>
        </form>
      </div>
      <div class="modal-backdrop" phx-click="close_domain_modal"></div>
    </div>
    """
  end

  defp deployment_card(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-md">
      <div class="card-body">
        <div class="flex justify-between items-center">
          <h2 class="card-title">
            <.icon name="hero-rocket-launch" class="h-5 w-5" />
            Deployment
          </h2>
          <div class="flex gap-2">
            <%= if @deployment && @deployment.registry_name do %>
              <button
                class="btn btn-primary btn-sm"
                phx-click="deploy_now"
                disabled={@deploying or @action_loading}
              >
                <%= if @deploying do %>
                  <span class="loading loading-spinner loading-xs"></span>
                <% else %>
                  <.icon name="hero-arrow-up-on-square" class="h-4 w-4" />
                <% end %>
                Deploy Now
              </button>
            <% end %>
            <button class="btn btn-ghost btn-sm" phx-click="open_deploy_modal">
              <.icon name="hero-cog-6-tooth" class="h-4 w-4" /> Configure
            </button>
          </div>
        </div>

        <%= if @deployment && @deployment.registry_name do %>
          <div class="space-y-2">
            <div class="flex items-center gap-2">
              <span class="text-sm font-medium">Image:</span>
              <code class="text-sm bg-base-200 px-2 py-1 rounded">
                {@deployment.repository_name}:{@deployment.tag}
              </code>
            </div>

            <div class="flex items-center gap-2">
              <span class="text-sm font-medium">Auto-deploy:</span>
              <input
                type="checkbox"
                class="toggle toggle-sm toggle-primary"
                checked={@deployment.auto_deploy}
                phx-click="toggle_auto_deploy"
              />
              <span class="text-sm text-base-content/60">
                <%= if @deployment.auto_deploy, do: "Enabled", else: "Disabled" %>
              </span>
            </div>

            <%= if @deployment.post_deploy_command do %>
              <div class="flex items-center gap-2">
                <span class="text-sm font-medium">Post-deploy:</span>
                <code class="text-sm bg-base-200 px-2 py-1 rounded">
                  {@deployment.post_deploy_command}
                </code>
              </div>
            <% end %>

            <%= if @deployment.last_deployed_at do %>
              <div class="flex items-center gap-2">
                <span class="text-sm font-medium">Last deploy:</span>
                <span class="text-sm text-base-content/60">
                  {Calendar.strftime(@deployment.last_deployed_at, "%Y-%m-%d %H:%M")}
                  <span class={[
                    "badge badge-sm ml-1",
                    @deployment.last_deploy_status == "success" && "badge-success",
                    @deployment.last_deploy_status == "failed" && "badge-error"
                  ]}>
                    {@deployment.last_deploy_status}
                  </span>
                </span>
              </div>
            <% end %>
          </div>
        <% else %>
          <p class="text-base-content/60">
            No container image linked. Configure deployment to enable auto-deploy from the registry.
          </p>
        <% end %>
      </div>
    </div>
    """
  end

  defp deploy_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box">
        <h3 class="font-bold text-lg">Configure Deployment</h3>
        <form phx-submit="save_deployment" phx-change="update_deploy_form" class="space-y-4 mt-4">
          <div class="form-control">
            <label class="label">
              <span class="label-text">Repository</span>
            </label>
            <select name="repository" class="select select-bordered" required>
              <option value="">Select a repository...</option>
              <%= for repo <- @repositories do %>
                <option value={repo["name"]} selected={@selected_repo == repo["name"]}>
                  {repo["name"]}
                </option>
              <% end %>
            </select>
          </div>

          <%= if @selected_repo && @tags != [] do %>
            <div class="form-control">
              <label class="label">
                <span class="label-text">Tag</span>
              </label>
              <select name="tag" class="select select-bordered">
                <%= for tag <- @tags do %>
                  <option value={tag["tag"]} selected={@selected_tag == tag["tag"]}>
                    {tag["tag"]}
                  </option>
                <% end %>
              </select>
              <label class="label">
                <span class="label-text-alt">Usually "latest" for auto-deploy</span>
              </label>
            </div>
          <% end %>

          <div class="form-control">
            <label class="label cursor-pointer justify-start gap-2">
              <input
                type="checkbox"
                name="auto_deploy"
                class="checkbox checkbox-primary"
                checked={@deployment && @deployment.auto_deploy}
              />
              <span class="label-text">Enable auto-deploy when new image is pushed</span>
            </label>
          </div>

          <div class="form-control">
            <label class="label">
              <span class="label-text">Post-deploy command</span>
            </label>
            <input
              type="text"
              name="post_deploy_command"
              value={@deployment && @deployment.post_deploy_command}
              class="input input-bordered font-mono"
              placeholder="/app/bin/migrate"
            />
            <label class="label">
              <span class="label-text-alt">Run after deploy (e.g., migrations). Uses <code>dokku run</code>.</span>
            </label>
          </div>

          <div class="modal-action">
            <%= if @deployment && @deployment.registry_name do %>
              <button
                type="button"
                class="btn btn-ghost text-error"
                phx-click="unlink_deployment"
              >
                Unlink
              </button>
            <% end %>
            <button type="button" class="btn" phx-click="close_deploy_modal">Cancel</button>
            <button type="submit" class="btn btn-primary" disabled={@saving or @selected_repo == nil}>
              <%= if @saving do %>
                <span class="loading loading-spinner loading-sm"></span>
              <% else %>
                Save
              <% end %>
            </button>
          </div>
        </form>
      </div>
      <div class="modal-backdrop" phx-click="close_deploy_modal"></div>
    </div>
    """
  end

  defp env_vars_card(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-md">
      <div class="card-body">
        <div class="flex justify-between items-center">
          <h2 class="card-title">
            <.icon name="hero-cog-6-tooth" class="h-5 w-5" />
            Environment Variables
          </h2>
          <div class="flex gap-2">
            <%= if @env_changed and not @action_loading do %>
              <button class="btn btn-warning btn-sm" phx-click="restart_app">
                <.icon name="hero-arrow-path" class="h-4 w-4" /> Restart to apply
              </button>
            <% end %>
            <button class="btn btn-primary btn-sm" phx-click="open_add_env_modal">
              <.icon name="hero-plus" class="h-4 w-4" /> Add Variable
            </button>
          </div>
        </div>

        <%= if @env_changed and not @action_loading do %>
          <div role="alert" class="alert alert-warning py-2">
            <.icon name="hero-exclamation-triangle" class="h-4 w-4" />
            <span class="text-sm">Environment changed. Restart the app to apply changes.</span>
          </div>
        <% end %>

        <%= if @env_vars && map_size(@env_vars) > 0 do %>
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Key</th>
                  <th>Value</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <%= for {key, value} <- Enum.sort(@env_vars) do %>
                  <tr>
                    <td class="font-mono text-sm">{key}</td>
                    <td class="font-mono text-sm max-w-xs truncate">
                      <%= if is_secret_key?(key) do %>
                        <span class="text-base-content/40">••••••••</span>
                      <% else %>
                        {value}
                      <% end %>
                    </td>
                    <td class="flex gap-1">
                      <button
                        class="btn btn-ghost btn-xs"
                        phx-click="open_edit_env_modal"
                        phx-value-key={key}
                        phx-value-value={value}
                      >
                        <.icon name="hero-pencil" class="h-3 w-3" />
                      </button>
                      <button
                        class="btn btn-ghost btn-xs text-error"
                        phx-click="delete_env"
                        phx-value-key={key}
                        data-confirm="Are you sure you want to delete this environment variable?"
                      >
                        <.icon name="hero-trash" class="h-3 w-3" />
                      </button>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        <% else %>
          <p class="text-base-content/60">No environment variables configured</p>
        <% end %>
      </div>
    </div>
    """
  end

  defp env_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box">
        <h3 class="font-bold text-lg">
          <%= if @editing, do: "Edit Environment Variable", else: "Add Environment Variable" %>
        </h3>
        <form phx-submit="save_env" class="space-y-4 mt-4">
          <%= if @editing do %>
            <input type="hidden" name="key" value={@editing} />
          <% end %>
          <div class="form-control">
            <label class="label">
              <span class="label-text">Key</span>
            </label>
            <input
              type="text"
              name={if @editing, do: "_key_display", else: "key"}
              value={@key}
              class="input input-bordered"
              placeholder="MY_ENV_VAR"
              required={@editing == nil}
              disabled={@editing != nil}
            />
          </div>

          <div class="form-control">
            <label class="label">
              <span class="label-text">Value</span>
            </label>
            <input
              type="text"
              name="value"
              value={@value}
              class="input input-bordered"
              placeholder="value"
            />
          </div>

          <div class="modal-action">
            <button type="button" class="btn" phx-click="close_env_modal">Cancel</button>
            <button type="submit" class="btn btn-primary" disabled={@saving}>
              <%= if @saving do %>
                <span class="loading loading-spinner loading-sm"></span>
              <% else %>
                Save
              <% end %>
            </button>
          </div>
        </form>
      </div>
      <div class="modal-backdrop" phx-click="close_env_modal"></div>
    </div>
    """
  end

  @impl true
  def handle_event("restart_app", _params, socket) do
    # Run restart async with streaming output
    droplet_id = socket.assigns.droplet_id
    app_name = socket.assigns.app_name
    pid = self()

    # Create a placeholder log entry for streaming output
    log_entry = %{
      id: System.unique_integer([:positive]),
      timestamp: DateTime.utc_now(),
      status: :running,
      command: "ps:restart #{app_name}",
      output: ""
    }

    logs = [log_entry | socket.assigns.ssh_logs] |> Enum.take(20)

    Task.start(fn ->
      result = SSH.restart_app_stream(droplet_id, app_name, pid)
      send(pid, {:restart_result, result})
    end)

    {:noreply,
     socket
     |> assign(:action_loading, true)
     |> assign(:ssh_logs, logs)
     |> assign(:streaming_output, "")}
  end

  def handle_event("open_add_env_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_env_modal, true)
     |> assign(:editing_env, nil)
     |> assign(:env_key, "")
     |> assign(:env_value, "")}
  end

  def handle_event("open_edit_env_modal", %{"key" => key, "value" => value}, socket) do
    {:noreply,
     socket
     |> assign(:show_env_modal, true)
     |> assign(:editing_env, key)
     |> assign(:env_key, key)
     |> assign(:env_value, value)}
  end

  def handle_event("close_env_modal", _params, socket) do
    {:noreply, assign(socket, :show_env_modal, false)}
  end

  def handle_event("save_env", params, socket) do
    key = params["key"] || socket.assigns.editing_env
    value = params["value"] || ""

    if key == nil or key == "" do
      {:noreply, put_flash(socket, :error, "Key is required")}
    else
      # Optimistically update the UI
      updated_env_vars = Map.put(socket.assigns.env_vars || %{}, key, value)

      # Run SSH command async
      droplet_id = socket.assigns.droplet_id
      app_name = socket.assigns.app_name
      pid = self()

      Task.start(fn ->
        result = SSH.set_env(droplet_id, app_name, key, value)
        send(pid, {:env_set_result, key, result})
      end)

      {:noreply,
       socket
       |> assign(:show_env_modal, false)
       |> assign(:saving, false)
       |> assign(:env_vars, updated_env_vars)
       |> assign(:env_changed, true)}
    end
  end

  def handle_event("delete_env", %{"key" => key}, socket) do
    # Optimistically update the UI
    updated_env_vars = Map.delete(socket.assigns.env_vars || %{}, key)

    # Run SSH command async
    droplet_id = socket.assigns.droplet_id
    app_name = socket.assigns.app_name
    pid = self()

    Task.start(fn ->
      result = SSH.unset_env(droplet_id, app_name, key)
      send(pid, {:env_unset_result, key, result})
    end)

    {:noreply,
     socket
     |> assign(:env_vars, updated_env_vars)
     |> assign(:env_changed, true)}
  end

  def handle_event("clear_ssh_log", _params, socket) do
    {:noreply, assign(socket, :ssh_logs, [])}
  end

  # Domain management events
  def handle_event("open_domain_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_domain_modal, true)
     |> assign(:new_domain, "")}
  end

  def handle_event("close_domain_modal", _params, socket) do
    {:noreply, assign(socket, :show_domain_modal, false)}
  end

  def handle_event("update_domain_form", %{"domain" => domain}, socket) do
    {:noreply, assign(socket, :new_domain, domain)}
  end

  def handle_event("add_domain", %{"domain" => domain}, socket) do
    domain = String.trim(domain)

    if domain == "" do
      {:noreply, put_flash(socket, :error, "Domain name is required")}
    else
      socket = assign(socket, :saving, true)
      droplet_id = socket.assigns.droplet_id
      app_name = socket.assigns.app_name
      pid = self()

      # Optimistically add domain to UI
      updated_domains = socket.assigns.domains ++ [domain]

      Task.start(fn ->
        result = SSH.add_domain(droplet_id, app_name, domain)
        send(pid, {:domain_add_result, domain, result})
      end)

      {:noreply,
       socket
       |> assign(:domains, updated_domains)
       |> assign(:show_domain_modal, false)
       |> assign(:saving, false)}
    end
  end

  def handle_event("delete_domain", %{"domain" => domain}, socket) do
    droplet_id = socket.assigns.droplet_id
    app_name = socket.assigns.app_name
    pid = self()

    # Optimistically remove domain from UI
    updated_domains = Enum.reject(socket.assigns.domains, &(&1 == domain))

    Task.start(fn ->
      result = SSH.remove_domain(droplet_id, app_name, domain)
      send(pid, {:domain_remove_result, domain, result})
    end)

    {:noreply, assign(socket, :domains, updated_domains)}
  end

  # Deployment events
  def handle_event("open_deploy_modal", _params, socket) do
    # Load repositories when opening modal
    case Registry.get() do
      {:ok, registry} ->
        case Registry.list_repositories(registry["name"]) do
          {:ok, repos} ->
            # Pre-select current repo if linked
            selected_repo =
              if socket.assigns.deployment && socket.assigns.deployment.repository_name do
                socket.assigns.deployment.repository_name
              else
                nil
              end

            socket =
              socket
              |> assign(:show_deploy_modal, true)
              |> assign(:repositories, repos)
              |> assign(:selected_repo, selected_repo)
              |> assign(:registry_name, registry["name"])

            # Load tags if repo is selected
            socket =
              if selected_repo do
                case Registry.list_tags(registry["name"], selected_repo) do
                  {:ok, tags} -> assign(socket, :tags, tags)
                  _ -> socket
                end
              else
                socket
              end

            {:noreply, socket}

          _ ->
            {:noreply, put_flash(socket, :error, "Failed to load repositories")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "No container registry configured")}
    end
  end

  def handle_event("close_deploy_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_deploy_modal, false)
     |> assign(:repositories, [])
     |> assign(:tags, [])}
  end

  def handle_event("update_deploy_form", %{"repository" => repo} = params, socket) do
    socket = assign(socket, :selected_repo, repo)

    # Load tags when repository changes
    socket =
      if repo != "" && socket.assigns[:registry_name] do
        case Registry.list_tags(socket.assigns.registry_name, repo) do
          {:ok, tags} ->
            socket
            |> assign(:tags, tags)
            |> assign(:selected_tag, params["tag"] || "latest")

          _ ->
            socket
        end
      else
        assign(socket, :tags, [])
      end

    {:noreply, socket}
  end

  def handle_event("save_deployment", params, socket) do
    droplet_id = socket.assigns.droplet_id
    app_name = socket.assigns.app_name
    registry_name = socket.assigns[:registry_name]
    repo = params["repository"]
    tag = params["tag"] || "latest"
    auto_deploy = params["auto_deploy"] == "true"
    post_deploy_command = params["post_deploy_command"]
    post_deploy_command = if post_deploy_command == "", do: nil, else: post_deploy_command

    opts = [
      tag: tag,
      auto_deploy: auto_deploy,
      post_deploy_command: post_deploy_command
    ]

    case Deployments.link_image(droplet_id, app_name, registry_name, repo, opts) do
      {:ok, deployment} ->
        {:noreply,
         socket
         |> assign(:deployment, deployment)
         |> assign(:show_deploy_modal, false)
         |> put_flash(:info, "Deployment configured")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to save deployment config")}
    end
  end

  def handle_event("unlink_deployment", _params, socket) do
    droplet_id = socket.assigns.droplet_id
    app_name = socket.assigns.app_name

    case Deployments.unlink_image(droplet_id, app_name) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:deployment, nil)
         |> assign(:show_deploy_modal, false)
         |> put_flash(:info, "Deployment unlinked")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to unlink deployment")}
    end
  end

  def handle_event("toggle_auto_deploy", _params, socket) do
    droplet_id = socket.assigns.droplet_id
    app_name = socket.assigns.app_name

    case Deployments.toggle_auto_deploy(droplet_id, app_name) do
      {:ok, deployment} ->
        {:noreply, assign(socket, :deployment, deployment)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to toggle auto-deploy")}
    end
  end

  def handle_event("deploy_now", _params, socket) do
    deployment = socket.assigns.deployment

    if deployment && deployment.registry_name do
      droplet_id = socket.assigns.droplet_id
      app_name = socket.assigns.app_name
      pid = self()

      # Fetch current digest to force Dokku to pull the latest image
      case Registry.list_tags(deployment.registry_name, deployment.repository_name) do
        {:ok, tags} ->
          case Enum.find(tags, &(&1["tag"] == deployment.tag)) do
            nil ->
              {:noreply, put_flash(socket, :error, "Tag #{deployment.tag} not found in registry")}

            tag_info ->
              digest = tag_info["manifest_digest"]
              # Use digest instead of tag to force Dokku to recognize the new image
              image_url = "registry.digitalocean.com/#{deployment.registry_name}/#{deployment.repository_name}@#{digest}"

              # Create a placeholder log entry for streaming output (show friendly tag in UI)
              display_url = "registry.digitalocean.com/#{deployment.registry_name}/#{deployment.repository_name}:#{deployment.tag}"
              log_entry = %{
                id: System.unique_integer([:positive]),
                timestamp: DateTime.utc_now(),
                status: :running,
                command: "git:from-image #{app_name} #{display_url}",
                output: ""
              }

              logs = [log_entry | socket.assigns.ssh_logs] |> Enum.take(20)

              Task.start(fn ->
                result = SSH.deploy_from_image_stream(droplet_id, app_name, image_url, pid)
                # Update digest after deploy
                case result do
                  {:ok, _} -> Deployments.update_digest(deployment, digest, "success")
                  {:error, _} -> Deployments.update_digest(deployment, deployment.last_digest, "failed")
                end
                send(pid, {:deploy_result, result})
              end)

              {:noreply,
               socket
               |> assign(:deploying, true)
               |> assign(:ssh_logs, logs)
               |> assign(:streaming_output, "")}
          end

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to fetch registry tags: #{inspect(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "No deployment configured")}
    end
  end

  defp is_secret_key?(key) do
    key = String.downcase(key)
    String.contains?(key, "secret") or
    String.contains?(key, "password") or
    String.contains?(key, "key") or
    String.contains?(key, "token") or
    String.contains?(key, "api_key")
  end

  defp add_ssh_log(socket, status, command, output) do
    log_entry = %{
      id: System.unique_integer([:positive]),
      timestamp: DateTime.utc_now(),
      status: status,
      command: command,
      output: output || ""
    }

    # Keep last 20 logs, newest first
    logs = [log_entry | socket.assigns.ssh_logs] |> Enum.take(20)

    assign(socket, :ssh_logs, logs)
  end
end
