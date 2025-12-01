defmodule KarotteControlWeb.DigitalOcean.RegistryLive do
  use KarotteControlWeb, :live_view

  alias KarotteControl.DigitalOcean.Registry

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Container Registry")
      |> assign(:registry, nil)
      |> assign(:subscription, nil)
      |> assign(:repositories, [])
      |> assign(:loading, true)
      |> assign(:error, nil)
      |> assign(:gc_running, false)

    if connected?(socket) do
      send(self(), :load_registry)
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:load_registry, socket) do
    socket =
      with {:ok, registry} <- Registry.get(),
           {:ok, subscription} <- Registry.get_subscription(),
           {:ok, repositories} <- Registry.list_repositories(registry["name"]) do
        socket
        |> assign(:registry, registry)
        |> assign(:subscription, subscription)
        |> assign(:repositories, repositories)
        |> assign(:loading, false)
      else
        {:error, {404, _}} ->
          socket
          |> assign(:error, "No container registry found. Create one in the DigitalOcean console.")
          |> assign(:loading, false)

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
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-bold">Container Registry</h1>
        <div class="flex gap-2">
          <%= if @registry do %>
            <button
              phx-click="garbage_collect"
              class="btn btn-warning btn-sm"
              disabled={@gc_running}
            >
              <%= if @gc_running do %>
                <span class="loading loading-spinner loading-xs"></span>
              <% else %>
                <.icon name="hero-trash" class="h-4 w-4 mr-1" />
              <% end %>
              Run Garbage Collection
            </button>
          <% end %>
          <button phx-click="refresh" class="btn btn-primary btn-sm">
            <.icon name="hero-arrow-path" class="h-4 w-4 mr-1" /> Refresh
          </button>
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
          <span>{@error}</span>
        </div>
      <% end %>

      <%= if @registry do %>
        <div class="grid gap-6 lg:grid-cols-2">
          <div class="card bg-base-100 shadow-md">
            <div class="card-body">
              <h2 class="card-title">Registry Info</h2>
              <dl class="space-y-2">
                <div>
                  <dt class="text-sm font-medium text-base-content/60">Name</dt>
                  <dd class="font-mono">{@registry["name"]}</dd>
                </div>
                <div>
                  <dt class="text-sm font-medium text-base-content/60">Region</dt>
                  <dd>{@registry["region"]}</dd>
                </div>
                <div>
                  <dt class="text-sm font-medium text-base-content/60">Created</dt>
                  <dd>{format_date(@registry["created_at"])}</dd>
                </div>
                <div>
                  <dt class="text-sm font-medium text-base-content/60">Storage Used</dt>
                  <dd>{format_bytes(@registry["storage_usage_bytes"])}</dd>
                </div>
              </dl>
            </div>
          </div>

          <%= if @subscription do %>
            <div class="card bg-base-100 shadow-md">
              <div class="card-body">
                <h2 class="card-title">Subscription</h2>
                <dl class="space-y-2">
                  <div>
                    <dt class="text-sm font-medium text-base-content/60">Tier</dt>
                    <dd>{get_in(@subscription, ["tier", "name"])}</dd>
                  </div>
                  <div>
                    <dt class="text-sm font-medium text-base-content/60">Storage Limit</dt>
                    <dd>{format_bytes(get_in(@subscription, ["tier", "included_storage_bytes"]))}</dd>
                  </div>
                  <div>
                    <dt class="text-sm font-medium text-base-content/60">Bandwidth Limit</dt>
                    <dd>{format_bytes(get_in(@subscription, ["tier", "included_bandwidth_bytes"]))}</dd>
                  </div>
                </dl>
              </div>
            </div>
          <% end %>
        </div>

        <div class="card bg-base-100 shadow-md">
          <div class="card-body">
            <h2 class="card-title">Repositories ({length(@repositories)})</h2>
            <%= if @repositories == [] do %>
              <p class="text-base-content/60">No repositories found</p>
            <% else %>
              <div class="overflow-x-auto">
                <table class="table table-zebra">
                  <thead>
                    <tr>
                      <th>Name</th>
                      <th>Tags</th>
                      <th>Manifests</th>
                      <th>Size</th>
                      <th>Updated</th>
                      <th></th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for repo <- @repositories do %>
                      <tr>
                        <td class="font-mono">{repo["name"]}</td>
                        <td>{repo["tag_count"]}</td>
                        <td>{repo["manifest_count"]}</td>
                        <td>{format_bytes(repo["compressed_size_bytes"])}</td>
                        <td>{format_date(repo["updated_at"])}</td>
                        <td>
                          <.link
                            navigate={~p"/digitalocean/registry/#{@registry["name"]}/#{repo["name"]}"}
                            class="btn btn-xs btn-ghost"
                          >
                            <.icon name="hero-eye" class="h-4 w-4" />
                          </.link>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp format_date(nil), do: "N/A"

  defp format_date(date_string) do
    case DateTime.from_iso8601(date_string) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M")
      _ -> date_string
    end
  end

  defp format_bytes(nil), do: "N/A"
  defp format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 2)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 2)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 2)} KB"
      true -> "#{bytes} B"
    end
  end
  defp format_bytes(_), do: "N/A"

  @impl true
  def handle_event("refresh", _params, socket) do
    socket =
      socket
      |> assign(:loading, true)
      |> assign(:error, nil)

    send(self(), :load_registry)
    {:noreply, socket}
  end

  @impl true
  def handle_event("garbage_collect", _params, socket) do
    registry_name = socket.assigns.registry["name"]

    socket = assign(socket, :gc_running, true)

    case Registry.start_garbage_collection(registry_name) do
      {:ok, _} ->
        # Poll for GC completion
        Process.send_after(self(), :check_gc_status, 2000)
        {:noreply, put_flash(socket, :info, "Garbage collection started")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:gc_running, false)
         |> put_flash(:error, "Failed to start garbage collection: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_info(:check_gc_status, socket) do
    registry_name = socket.assigns.registry["name"]

    case Registry.get_garbage_collection(registry_name) do
      {:ok, %{"status" => status}} when status in ["succeeded", "failed", "cancelled"] ->
        # GC finished, reload registry data
        send(self(), :load_registry)

        socket =
          socket
          |> assign(:gc_running, false)
          |> put_flash(:info, "Garbage collection #{status}")

        {:noreply, socket}

      {:ok, _gc} ->
        # Still running, check again
        Process.send_after(self(), :check_gc_status, 3000)
        {:noreply, socket}

      {:error, _} ->
        # Error checking status, stop polling
        {:noreply, assign(socket, :gc_running, false)}
    end
  end
end
