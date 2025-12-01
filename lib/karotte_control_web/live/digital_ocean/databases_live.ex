defmodule KarotteControlWeb.DigitalOcean.DatabasesLive do
  use KarotteControlWeb, :live_view

  alias KarotteControl.DigitalOcean.Databases
  alias KarotteControl.DigitalOcean.Projects

  @impl true
  def mount(_params, session, socket) do
    project_id = session["selected_project_id"]

    socket =
      socket
      |> assign(:page_title, "Databases")
      |> assign(:databases, [])
      |> assign(:loading, true)
      |> assign(:error, nil)
      |> assign(:project_id, project_id)

    if connected?(socket) do
      send(self(), :load_databases)
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:load_databases, socket) do
    project_id = socket.assigns[:project_id]

    socket =
      case load_databases_for_project(project_id) do
        {:ok, databases} ->
          socket
          |> assign(:databases, databases)
          |> assign(:loading, false)

        {:error, reason} ->
          socket
          |> assign(:error, inspect(reason))
          |> assign(:loading, false)
      end

    {:noreply, socket}
  end

  defp load_databases_for_project(nil) do
    Databases.list()
  end

  defp load_databases_for_project(project_id) do
    with {:ok, resources} <- Projects.list_resources(project_id),
         {:ok, all_databases} <- Databases.list() do
      # Get database URNs from project resources
      db_urns = Projects.extract_urns_by_type(resources, "dbaas")
      db_ids = Enum.map(db_urns, &Projects.extract_id_from_urn/1)

      # Filter databases to only those in this project
      filtered_databases = Enum.filter(all_databases, &(&1["id"] in db_ids))
      {:ok, filtered_databases}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-bold">DigitalOcean Databases</h1>
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
        <%= if @databases == [] do %>
          <div class="text-center py-12 text-base-content/60">
            <.icon name="hero-circle-stack" class="h-12 w-12 mx-auto mb-4" />
            <p>No databases found</p>
          </div>
        <% else %>
          <div class="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
            <%= for db <- @databases do %>
              <.database_card db={db} />
            <% end %>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  defp database_card(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-md">
      <div class="card-body">
        <h2 class="card-title">
          {@db["name"]}
          <.status_badge status={@db["status"]} />
        </h2>
        <div class="space-y-1 text-sm">
          <p class="text-base-content/60">
            <span class="font-medium">Engine:</span> {@db["engine"]} {@db["version"]}
          </p>
          <p class="text-base-content/60">
            <span class="font-medium">Region:</span> {@db["region"]}
          </p>
          <p class="text-base-content/60">
            <span class="font-medium">Size:</span> {@db["size"]}
          </p>
          <p class="text-base-content/60">
            <span class="font-medium">Nodes:</span> {@db["num_nodes"]}
          </p>
          <p class="text-base-content/60">
            <span class="font-medium">Created:</span> {format_date(@db["created_at"])}
          </p>
        </div>
        <div class="card-actions justify-end mt-4">
          <.link navigate={~p"/digitalocean/databases/#{@db["id"]}"} class="btn btn-sm btn-outline">
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
        "online" -> "badge-success"
        "creating" -> "badge-warning"
        "resizing" -> "badge-info"
        "migrating" -> "badge-info"
        "forking" -> "badge-info"
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

    send(self(), :load_databases)
    {:noreply, socket}
  end
end
