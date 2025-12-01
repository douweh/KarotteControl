defmodule KarotteControlWeb.DigitalOcean.AppShowLive do
  use KarotteControlWeb, :live_view

  alias KarotteControl.DigitalOcean.Apps

  @impl true
  def mount(%{"id" => app_id}, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "App Details")
      |> assign(:app_id, app_id)
      |> assign(:app, nil)
      |> assign(:deployments, [])
      |> assign(:loading, true)
      |> assign(:error, nil)

    if connected?(socket) do
      send(self(), :load_app)
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:load_app, socket) do
    app_id = socket.assigns.app_id

    socket =
      with {:ok, app} <- Apps.get(app_id),
           {:ok, deployments} <- Apps.list_deployments(app_id) do
        socket
        |> assign(:app, app)
        |> assign(:deployments, Enum.take(deployments, 10))
        |> assign(:page_title, get_in(app, ["spec", "name"]) || "App Details")
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

      <%= if @app do %>
        <div class="grid gap-6 lg:grid-cols-2">
          <div class="card bg-base-100 shadow-md">
            <div class="card-body">
              <h2 class="card-title">Overview</h2>
              <dl class="space-y-2">
                <div>
                  <dt class="text-sm font-medium text-base-content/60">App ID</dt>
                  <dd class="font-mono text-sm">{@app["id"]}</dd>
                </div>
                <div>
                  <dt class="text-sm font-medium text-base-content/60">Region</dt>
                  <dd>{@app["region"]["slug"]}</dd>
                </div>
                <div>
                  <dt class="text-sm font-medium text-base-content/60">Tier</dt>
                  <dd>{@app["tier_slug"]}</dd>
                </div>
                <div>
                  <dt class="text-sm font-medium text-base-content/60">Live URL</dt>
                  <dd>
                    <%= if url = @app["live_url"] do %>
                      <a href={url} target="_blank" class="link link-primary">{url}</a>
                    <% else %>
                      N/A
                    <% end %>
                  </dd>
                </div>
                <div>
                  <dt class="text-sm font-medium text-base-content/60">Created</dt>
                  <dd>{format_date(@app["created_at"])}</dd>
                </div>
                <div>
                  <dt class="text-sm font-medium text-base-content/60">Updated</dt>
                  <dd>{format_date(@app["updated_at"])}</dd>
                </div>
              </dl>
            </div>
          </div>

          <div class="card bg-base-100 shadow-md">
            <div class="card-body">
              <h2 class="card-title">Services</h2>
              <%= if services = get_in(@app, ["spec", "services"]) do %>
                <div class="space-y-3">
                  <%= for service <- services do %>
                    <div class="p-3 bg-base-200 rounded-lg">
                      <div class="font-medium">{service["name"]}</div>
                      <div class="text-sm text-base-content/60">
                        Instance: {service["instance_size_slug"]}
                      </div>
                      <div class="text-sm text-base-content/60">
                        Instances: {service["instance_count"]}
                      </div>
                    </div>
                  <% end %>
                </div>
              <% else %>
                <p class="text-base-content/60">No services configured</p>
              <% end %>
            </div>
          </div>
        </div>

        <div class="card bg-base-100 shadow-md">
          <div class="card-body">
            <h2 class="card-title">Recent Deployments</h2>
            <%= if @deployments == [] do %>
              <p class="text-base-content/60">No deployments found</p>
            <% else %>
              <div class="overflow-x-auto">
                <table class="table table-zebra">
                  <thead>
                    <tr>
                      <th>Phase</th>
                      <th>Cause</th>
                      <th>Created</th>
                      <th>Updated</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for deployment <- @deployments do %>
                      <tr>
                        <td>
                          <.deployment_status_badge phase={deployment["phase"]} />
                        </td>
                        <td>{deployment["cause"]}</td>
                        <td>{format_date(deployment["created_at"])}</td>
                        <td>{format_date(deployment["updated_at"])}</td>
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

  defp deployment_status_badge(assigns) do
    color =
      case assigns.phase do
        "ACTIVE" -> "badge-success"
        "DEPLOYING" -> "badge-warning"
        "BUILDING" -> "badge-info"
        "ERROR" -> "badge-error"
        "CANCELED" -> "badge-ghost"
        _ -> "badge-ghost"
      end

    assigns = assign(assigns, :color, color)

    ~H"""
    <span class={"badge #{@color} badge-sm"}>{@phase}</span>
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
