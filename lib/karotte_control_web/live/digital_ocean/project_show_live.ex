defmodule KarotteControlWeb.DigitalOcean.ProjectShowLive do
  use KarotteControlWeb, :live_view

  alias KarotteControl.DigitalOcean.{Projects, Apps, Databases}

  @impl true
  def mount(%{"project_id" => project_id}, _session, socket) do
    socket =
      socket
      |> assign(:project_id, project_id)
      |> assign(:project, nil)
      |> assign(:resources, [])
      |> assign(:apps, [])
      |> assign(:databases, [])
      |> assign(:loading, true)
      |> assign(:error, nil)

    if connected?(socket) do
      send(self(), :load_project)
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:load_project, socket) do
    project_id = socket.assigns.project_id

    socket =
      with {:ok, project} <- Projects.get(project_id),
           {:ok, resources} <- Projects.list_resources(project_id),
           {:ok, apps} <- load_apps(resources),
           {:ok, databases} <- load_databases(resources) do
        socket
        |> assign(:page_title, project["name"])
        |> assign(:project, project)
        |> assign(:resources, resources)
        |> assign(:apps, apps)
        |> assign(:databases, databases)
        |> assign(:loading, false)
      else
        {:error, reason} ->
          socket
          |> assign(:error, inspect(reason))
          |> assign(:loading, false)
      end

    {:noreply, socket}
  end

  defp load_apps(resources) do
    app_urns = Projects.extract_urns_by_type(resources, "app")

    if app_urns == [] do
      {:ok, []}
    else
      app_ids = Enum.map(app_urns, &Projects.extract_id_from_urn/1)

      case Apps.list() do
        {:ok, all_apps} ->
          {:ok, Enum.filter(all_apps, &(&1["id"] in app_ids))}

        error ->
          error
      end
    end
  end

  defp load_databases(resources) do
    db_urns = Projects.extract_urns_by_type(resources, "dbaas")

    if db_urns == [] do
      {:ok, []}
    else
      db_ids = Enum.map(db_urns, &Projects.extract_id_from_urn/1)

      case Databases.list() do
        {:ok, all_dbs} ->
          {:ok, Enum.filter(all_dbs, &(&1["id"] in db_ids))}

        error ->
          error
      end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
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

      <%= if @project do %>
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-bold">{@project["name"]}</h1>
            <p class="text-base-content/60">{@project["description"]}</p>
          </div>
          <button phx-click="refresh" class="btn btn-primary btn-sm">
            <.icon name="hero-arrow-path" class="h-4 w-4 mr-1" /> Refresh
          </button>
        </div>

        <div class="grid gap-6 lg:grid-cols-2">
          <div class="card bg-base-100 shadow-md">
            <div class="card-body">
              <h2 class="card-title">
                <.icon name="hero-rocket-launch" class="h-5 w-5" />
                Apps ({length(@apps)})
              </h2>
              <%= if @apps == [] do %>
                <p class="text-base-content/60">No apps in this project</p>
              <% else %>
                <div class="space-y-3">
                  <%= for app <- @apps do %>
                    <.app_item app={app} />
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>

          <div class="card bg-base-100 shadow-md">
            <div class="card-body">
              <h2 class="card-title">
                <.icon name="hero-circle-stack" class="h-5 w-5" />
                Databases ({length(@databases)})
              </h2>
              <%= if @databases == [] do %>
                <p class="text-base-content/60">No databases in this project</p>
              <% else %>
                <div class="space-y-3">
                  <%= for db <- @databases do %>
                    <.database_item db={db} />
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>
        </div>

        <%= if has_other_resources?(@resources) do %>
          <div class="card bg-base-100 shadow-md">
            <div class="card-body">
              <h2 class="card-title">
                <.icon name="hero-cube" class="h-5 w-5" />
                Other Resources
              </h2>
              <div class="space-y-2">
                <%= for resource <- other_resources(@resources) do %>
                  <div class="flex items-center gap-2 text-sm">
                    <span class="badge badge-ghost">{resource_type(resource["urn"])}</span>
                    <span class="font-mono text-xs">{resource["urn"]}</span>
                  </div>
                <% end %>
              </div>
            </div>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  defp app_item(assigns) do
    ~H"""
    <div class="flex items-center justify-between p-3 bg-base-200 rounded-lg">
      <div>
        <div class="font-medium">{@app["spec"]["name"]}</div>
        <div class="text-sm text-base-content/60">
          {get_in(@app, ["region", "slug"])}
          <.status_badge status={get_in(@app, ["active_deployment", "phase"]) || "unknown"} />
        </div>
      </div>
      <.link navigate={~p"/digitalocean/apps/#{@app["id"]}"} class="btn btn-sm btn-ghost">
        <.icon name="hero-arrow-right" class="h-4 w-4" />
      </.link>
    </div>
    """
  end

  defp database_item(assigns) do
    ~H"""
    <div class="flex items-center justify-between p-3 bg-base-200 rounded-lg">
      <div>
        <div class="font-medium">{@db["name"]}</div>
        <div class="text-sm text-base-content/60">
          {@db["engine"]} {@db["version"]} · {@db["region"]}
          <.status_badge status={@db["status"]} />
        </div>
      </div>
      <.link navigate={~p"/digitalocean/databases/#{@db["id"]}"} class="btn btn-sm btn-ghost">
        <.icon name="hero-arrow-right" class="h-4 w-4" />
      </.link>
    </div>
    """
  end

  defp status_badge(assigns) do
    color =
      case assigns.status do
        status when status in ["ACTIVE", "online"] -> "badge-success"
        status when status in ["DEPLOYING", "creating", "resizing"] -> "badge-warning"
        status when status in ["ERROR"] -> "badge-error"
        _ -> "badge-ghost"
      end

    assigns = assign(assigns, :color, color)

    ~H"""
    <span class={"badge #{@color} badge-xs ml-2"}>{@status}</span>
    """
  end

  defp has_other_resources?(resources) do
    other_resources(resources) != []
  end

  defp other_resources(resources) do
    Enum.reject(resources, fn r ->
      urn = r["urn"]
      String.starts_with?(urn, "do:app:") or String.starts_with?(urn, "do:dbaas:")
    end)
  end

  defp resource_type(urn) do
    case String.split(urn, ":") do
      ["do", type | _] -> type
      _ -> "unknown"
    end
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    socket =
      socket
      |> assign(:loading, true)
      |> assign(:error, nil)

    send(self(), :load_project)
    {:noreply, socket}
  end
end
