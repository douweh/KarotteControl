defmodule KarotteControlWeb.DigitalOcean.DatabaseShowLive do
  use KarotteControlWeb, :live_view

  alias KarotteControl.DigitalOcean.Databases

  @impl true
  def mount(%{"id" => database_id}, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Database Details")
      |> assign(:database_id, database_id)
      |> assign(:database, nil)
      |> assign(:dbs, [])
      |> assign(:users, [])
      |> assign(:pools, [])
      |> assign(:loading, true)
      |> assign(:error, nil)

    if connected?(socket) do
      send(self(), :load_database)
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:load_database, socket) do
    database_id = socket.assigns.database_id

    socket =
      with {:ok, database} <- Databases.get(database_id),
           {:ok, dbs} <- Databases.list_dbs(database_id),
           {:ok, users} <- Databases.list_users(database_id),
           {:ok, pools} <- Databases.list_pools(database_id) do
        socket
        |> assign(:database, database)
        |> assign(:dbs, dbs)
        |> assign(:users, users)
        |> assign(:pools, pools)
        |> assign(:page_title, database["name"] || "Database Details")
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
        <h1 class="text-2xl font-bold">{@page_title}</h1>
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

      <%= if @database do %>
        <div class="grid gap-6 lg:grid-cols-2">
          <div class="card bg-base-100 shadow-md">
            <div class="card-body">
              <h2 class="card-title">Overview</h2>
              <dl class="space-y-2">
                <div>
                  <dt class="text-sm font-medium text-base-content/60">Cluster ID</dt>
                  <dd class="font-mono text-sm">{@database["id"]}</dd>
                </div>
                <div>
                  <dt class="text-sm font-medium text-base-content/60">Status</dt>
                  <dd><.status_badge status={@database["status"]} /></dd>
                </div>
                <div>
                  <dt class="text-sm font-medium text-base-content/60">Engine</dt>
                  <dd>{@database["engine"]} {@database["version"]}</dd>
                </div>
                <div>
                  <dt class="text-sm font-medium text-base-content/60">Region</dt>
                  <dd>{@database["region"]}</dd>
                </div>
                <div>
                  <dt class="text-sm font-medium text-base-content/60">Size</dt>
                  <dd>{@database["size"]}</dd>
                </div>
                <div>
                  <dt class="text-sm font-medium text-base-content/60">Nodes</dt>
                  <dd>{@database["num_nodes"]}</dd>
                </div>
                <div>
                  <dt class="text-sm font-medium text-base-content/60">Created</dt>
                  <dd>{format_date(@database["created_at"])}</dd>
                </div>
              </dl>
            </div>
          </div>

          <div class="card bg-base-100 shadow-md">
            <div class="card-body">
              <h2 class="card-title">Connection</h2>
              <%= if conn = @database["connection"] do %>
                <dl class="space-y-2">
                  <div>
                    <dt class="text-sm font-medium text-base-content/60">Host</dt>
                    <dd class="font-mono text-sm">{conn["host"]}</dd>
                  </div>
                  <div>
                    <dt class="text-sm font-medium text-base-content/60">Port</dt>
                    <dd>{conn["port"]}</dd>
                  </div>
                  <div>
                    <dt class="text-sm font-medium text-base-content/60">Database</dt>
                    <dd>{conn["database"]}</dd>
                  </div>
                  <div>
                    <dt class="text-sm font-medium text-base-content/60">User</dt>
                    <dd>{conn["user"]}</dd>
                  </div>
                  <div>
                    <dt class="text-sm font-medium text-base-content/60">SSL</dt>
                    <dd>{if conn["ssl"], do: "Required", else: "Optional"}</dd>
                  </div>
                </dl>
              <% else %>
                <p class="text-base-content/60">Connection info not available</p>
              <% end %>
            </div>
          </div>
        </div>

        <div class="grid gap-6 lg:grid-cols-3">
          <div class="card bg-base-100 shadow-md">
            <div class="card-body">
              <h2 class="card-title">Databases ({length(@dbs)})</h2>
              <%= if @dbs == [] do %>
                <p class="text-base-content/60">No databases</p>
              <% else %>
                <ul class="space-y-1">
                  <%= for db <- @dbs do %>
                    <li class="font-mono text-sm">{db["name"]}</li>
                  <% end %>
                </ul>
              <% end %>
            </div>
          </div>

          <div class="card bg-base-100 shadow-md">
            <div class="card-body">
              <h2 class="card-title">Users ({length(@users)})</h2>
              <%= if @users == [] do %>
                <p class="text-base-content/60">No users</p>
              <% else %>
                <ul class="space-y-1">
                  <%= for user <- @users do %>
                    <li class="font-mono text-sm">
                      {user["name"]}
                      <%= if user["role"] do %>
                        <span class="badge badge-ghost badge-xs ml-1">{user["role"]}</span>
                      <% end %>
                    </li>
                  <% end %>
                </ul>
              <% end %>
            </div>
          </div>

          <div class="card bg-base-100 shadow-md">
            <div class="card-body">
              <h2 class="card-title">Connection Pools ({length(@pools)})</h2>
              <%= if @pools == [] do %>
                <p class="text-base-content/60">No pools configured</p>
              <% else %>
                <ul class="space-y-2">
                  <%= for pool <- @pools do %>
                    <li class="p-2 bg-base-200 rounded">
                      <div class="font-mono text-sm">{pool["name"]}</div>
                      <div class="text-xs text-base-content/60">
                        Mode: {pool["mode"]} | Size: {pool["size"]}
                      </div>
                    </li>
                  <% end %>
                </ul>
              <% end %>
            </div>
          </div>
        </div>
      <% end %>
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
end
