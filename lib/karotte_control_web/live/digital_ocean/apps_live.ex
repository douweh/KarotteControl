defmodule KarotteControlWeb.DigitalOcean.AppsLive do
  use KarotteControlWeb, :live_view

  alias KarotteControl.DigitalOcean.Apps
  alias KarotteControl.DigitalOcean.Projects

  @impl true
  def mount(_params, session, socket) do
    project_id = session["selected_project_id"]

    socket =
      socket
      |> assign(:page_title, "Apps")
      |> assign(:apps, [])
      |> assign(:loading, true)
      |> assign(:error, nil)
      |> assign(:project_id, project_id)

    if connected?(socket) do
      send(self(), :load_apps)
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:load_apps, socket) do
    project_id = socket.assigns[:project_id]

    socket =
      case load_apps_for_project(project_id) do
        {:ok, apps} ->
          socket
          |> assign(:apps, apps)
          |> assign(:loading, false)

        {:error, reason} ->
          socket
          |> assign(:error, inspect(reason))
          |> assign(:loading, false)
      end

    {:noreply, socket}
  end

  defp load_apps_for_project(nil) do
    Apps.list()
  end

  defp load_apps_for_project(project_id) do
    with {:ok, resources} <- Projects.list_resources(project_id),
         {:ok, all_apps} <- Apps.list() do
      # Get app URNs from project resources
      app_urns = Projects.extract_urns_by_type(resources, "app")
      app_ids = Enum.map(app_urns, &Projects.extract_id_from_urn/1)

      # Filter apps to only those in this project
      filtered_apps = Enum.filter(all_apps, &(&1["id"] in app_ids))
      {:ok, filtered_apps}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-bold">DigitalOcean Apps</h1>
        <button phx-click="refresh" class="btn btn-primary btn-sm">
          <.icon name="hero-arrow-path" class="h-4 w-4 mr-1" /> Refresh
        </button>
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

      <%= if !@loading and @error == nil do %>
        <%= if @apps == [] do %>
          <div class="text-center py-12 text-base-content/60">
            <.icon name="hero-cube" class="h-12 w-12 mx-auto mb-4" />
            <p>No apps found</p>
          </div>
        <% else %>
          <div class="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
            <%= for app <- @apps do %>
              <.app_card app={app} />
            <% end %>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  defp app_card(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-md">
      <div class="card-body">
        <h2 class="card-title">
          {@app["spec"]["name"]}
          <.status_badge status={get_in(@app, ["active_deployment", "phase"]) || "unknown"} />
        </h2>
        <p class="text-sm text-base-content/60">
          Region: {@app["region"]["slug"]}
        </p>
        <p class="text-sm text-base-content/60">
          Created: {format_date(@app["created_at"])}
        </p>
        <%= if url = @app["live_url"] do %>
          <a href={url} target="_blank" class="link link-primary text-sm">
            {url}
          </a>
        <% end %>
        <div class="card-actions justify-end mt-4">
          <.link navigate={~p"/digitalocean/apps/#{@app["id"]}"} class="btn btn-sm btn-outline">
            View Details
          </.link>
        </div>
      </div>
    </div>
    """
  end

  defp status_badge(assigns) do
    color =
      case assigns.status do
        "ACTIVE" -> "badge-success"
        "DEPLOYING" -> "badge-warning"
        "ERROR" -> "badge-error"
        _ -> "badge-ghost"
      end

    assigns = assign(assigns, :color, color)

    ~H"""
    <span class={"badge #{@color} badge-sm"}>{@status}</span>
    """
  end

  defp format_date(nil), do: "N/A"

  defp format_date(date_string) do
    case DateTime.from_iso8601(date_string) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M")
      _ -> date_string
    end
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    socket =
      socket
      |> assign(:loading, true)
      |> assign(:error, nil)

    send(self(), :load_apps)
    {:noreply, socket}
  end
end
