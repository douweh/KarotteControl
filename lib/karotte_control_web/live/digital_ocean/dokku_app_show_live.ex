defmodule KarotteControlWeb.DigitalOcean.DokkuAppShowLive do
  use KarotteControlWeb, :live_view

  alias KarotteControl.DigitalOcean.Droplets
  alias KarotteControl.Dokku.SSH

  @impl true
  def mount(%{"droplet_id" => droplet_id, "app_name" => app_name}, _session, socket) do
    socket =
      socket
      |> assign(:droplet_id, droplet_id)
      |> assign(:app_name, app_name)
      |> assign(:droplet, nil)
      |> assign(:app_info, nil)
      |> assign(:domains, nil)
      |> assign(:env_vars, nil)
      |> assign(:loading, true)
      |> assign(:error, nil)
      |> assign(:action_loading, false)

    if connected?(socket) do
      send(self(), :load_data)
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:load_data, socket) do
    droplet_id = socket.assigns.droplet_id
    app_name = socket.assigns.app_name

    socket =
      with {:ok, droplet} <- Droplets.get(droplet_id),
           {:ok, app_info} <- SSH.app_info(droplet_id, app_name),
           {:ok, domains} <- SSH.app_domains(droplet_id, app_name),
           {:ok, env_vars} <- SSH.get_env(droplet_id, app_name) do
        socket
        |> assign(:page_title, "#{app_name} on #{droplet["name"]}")
        |> assign(:droplet, droplet)
        |> assign(:app_info, app_info)
        |> assign(:domains, domains)
        |> assign(:env_vars, env_vars)
        |> assign(:loading, false)
      else
        {:error, reason} ->
          socket
          |> assign(:error, inspect(reason))
          |> assign(:loading, false)
      end

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
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
        <div class="grid gap-6 lg:grid-cols-2">
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

          <!-- Domains Card -->
          <div class="card bg-base-100 shadow-md">
            <div class="card-body">
              <h2 class="card-title">
                <.icon name="hero-globe-alt" class="h-5 w-5" />
                Domains
              </h2>
              <%= if @domains do %>
                <div class="overflow-x-auto">
                  <table class="table table-sm">
                    <tbody>
                      <%= for {key, value} <- @domains do %>
                        <tr>
                          <th class="font-mono text-xs">{key}</th>
                          <td class="font-mono text-xs">
                            <%= if String.contains?(key, "vhost") or String.contains?(key, "domain") do %>
                              <a href={"https://#{value}"} target="_blank" class="link link-primary">{value}</a>
                            <% else %>
                              {value}
                            <% end %>
                          </td>
                        </tr>
                      <% end %>
                    </tbody>
                  </table>
                </div>
              <% else %>
                <p class="text-base-content/60">No domains configured</p>
              <% end %>
            </div>
          </div>
        </div>

        <!-- Environment Variables Card -->
        <div class="card bg-base-100 shadow-md">
          <div class="card-body">
            <h2 class="card-title">
              <.icon name="hero-cog-6-tooth" class="h-5 w-5" />
              Environment Variables
            </h2>
            <%= if @env_vars && map_size(@env_vars) > 0 do %>
              <div class="overflow-x-auto">
                <table class="table table-sm">
                  <thead>
                    <tr>
                      <th>Key</th>
                      <th>Value</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for {key, value} <- Enum.sort(@env_vars) do %>
                      <tr>
                        <td class="font-mono text-sm">{key}</td>
                        <td class="font-mono text-sm max-w-md truncate">
                          <%= if is_secret_key?(key) do %>
                            <span class="text-base-content/40">••••••••</span>
                          <% else %>
                            {value}
                          <% end %>
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
      <% end %>
    </div>
    """
  end

  @impl true
  def handle_event("restart_app", _params, socket) do
    socket = assign(socket, :action_loading, true)

    case SSH.restart_app(socket.assigns.droplet_id, socket.assigns.app_name) do
      {:ok, _} ->
        send(self(), :load_data)
        {:noreply,
         socket
         |> assign(:action_loading, false)
         |> put_flash(:info, "App restart initiated")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:action_loading, false)
         |> put_flash(:error, "Failed to restart: #{inspect(reason)}")}
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
end
