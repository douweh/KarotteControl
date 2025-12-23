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
      |> assign(:show_env_modal, false)
      |> assign(:editing_env, nil)
      |> assign(:env_form, to_form(%{"key" => "", "value" => "", "type" => "GENERAL", "scope" => "RUN_AND_BUILD_TIME"}))
      |> assign(:saving, false)
      |> assign(:show_domain_modal, false)
      |> assign(:new_domain, "")
      |> assign(:new_domain_type, "PRIMARY")

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
  def handle_event("open_add_env_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_env_modal, true)
     |> assign(:editing_env, nil)
     |> assign(:env_form, to_form(%{"key" => "", "value" => "", "type" => "GENERAL", "scope" => "RUN_AND_BUILD_TIME"}))}
  end

  def handle_event("open_edit_env_modal", %{"key" => key}, socket) do
    app_envs = get_in(socket.assigns.app, ["spec", "envs"]) || []
    env = Enum.find(app_envs, &(&1["key"] == key))

    if env do
      {:noreply,
       socket
       |> assign(:show_env_modal, true)
       |> assign(:editing_env, key)
       |> assign(:env_form, to_form(%{
         "key" => env["key"],
         "value" => env["value"] || "",
         "type" => env["type"] || "GENERAL",
         "scope" => env["scope"] || "RUN_AND_BUILD_TIME"
       }))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_env_modal", _params, socket) do
    {:noreply, assign(socket, :show_env_modal, false)}
  end

  def handle_event("save_env", params, socket) do
    # When editing, key is disabled so we use the editing_env value
    key = params["key"] || socket.assigns.editing_env
    value = params["value"]
    type = params["type"]
    scope = params["scope"]
    socket = assign(socket, :saving, true)

    app = socket.assigns.app
    spec = app["spec"]
    current_envs = spec["envs"] || []

    new_env = %{
      "key" => key,
      "value" => value,
      "type" => type,
      "scope" => scope
    }

    updated_envs =
      if socket.assigns.editing_env do
        Enum.map(current_envs, fn env ->
          if env["key"] == socket.assigns.editing_env, do: new_env, else: env
        end)
      else
        current_envs ++ [new_env]
      end

    updated_spec = Map.put(spec, "envs", updated_envs)

    case Apps.update(app["id"], updated_spec) do
      {:ok, updated_app} ->
        {:noreply,
         socket
         |> assign(:app, updated_app)
         |> assign(:show_env_modal, false)
         |> assign(:saving, false)
         |> put_flash(:info, "Environment variable saved. Deployment triggered.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:saving, false)
         |> put_flash(:error, "Failed to save: #{inspect(reason)}")}
    end
  end

  def handle_event("delete_env", %{"key" => key}, socket) do
    app = socket.assigns.app
    spec = app["spec"]
    current_envs = spec["envs"] || []

    updated_envs = Enum.reject(current_envs, &(&1["key"] == key))
    updated_spec = Map.put(spec, "envs", updated_envs)

    case Apps.update(app["id"], updated_spec) do
      {:ok, updated_app} ->
        {:noreply,
         socket
         |> assign(:app, updated_app)
         |> put_flash(:info, "Environment variable deleted. Deployment triggered.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete: #{inspect(reason)}")}
    end
  end

  # Domain management events
  def handle_event("open_domain_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_domain_modal, true)
     |> assign(:new_domain, "")
     |> assign(:new_domain_type, "PRIMARY")}
  end

  def handle_event("close_domain_modal", _params, socket) do
    {:noreply, assign(socket, :show_domain_modal, false)}
  end

  def handle_event("update_domain_form", params, socket) do
    socket =
      socket
      |> assign(:new_domain, params["domain"] || socket.assigns.new_domain)
      |> assign(:new_domain_type, params["type"] || socket.assigns.new_domain_type)

    {:noreply, socket}
  end

  def handle_event("add_domain", %{"domain" => domain, "type" => type}, socket) do
    domain = String.trim(domain)

    if domain == "" do
      {:noreply, put_flash(socket, :error, "Domain name is required")}
    else
      socket = assign(socket, :saving, true)

      app = socket.assigns.app
      spec = app["spec"]
      current_domains = spec["domains"] || []

      new_domain = %{
        "domain" => domain,
        "type" => type
      }

      updated_domains = current_domains ++ [new_domain]
      updated_spec = Map.put(spec, "domains", updated_domains)

      case Apps.update(app["id"], updated_spec) do
        {:ok, updated_app} ->
          {:noreply,
           socket
           |> assign(:app, updated_app)
           |> assign(:show_domain_modal, false)
           |> assign(:saving, false)
           |> put_flash(:info, "Domain added. Deployment triggered.")}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(:saving, false)
           |> put_flash(:error, "Failed to add domain: #{inspect(reason)}")}
      end
    end
  end

  def handle_event("delete_domain", %{"domain" => domain}, socket) do
    app = socket.assigns.app
    spec = app["spec"]
    current_domains = spec["domains"] || []

    updated_domains = Enum.reject(current_domains, &(&1["domain"] == domain))
    updated_spec = Map.put(spec, "domains", updated_domains)

    case Apps.update(app["id"], updated_spec) do
      {:ok, updated_app} ->
        {:noreply,
         socket
         |> assign(:app, updated_app)
         |> put_flash(:info, "Domain removed. Deployment triggered.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to remove domain: #{inspect(reason)}")}
    end
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

        <.env_vars_card app={@app} />

        <.domains_card app={@app} />

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

      <.env_modal
        :if={@show_env_modal}
        form={@env_form}
        editing={@editing_env}
        saving={@saving}
      />

      <.domain_modal
        :if={@show_domain_modal}
        domain={@new_domain}
        type={@new_domain_type}
        saving={@saving}
      />
    </div>
    """
  end

  defp domains_card(assigns) do
    domains = get_in(assigns.app, ["spec", "domains"]) || []
    assigns = assign(assigns, :domains, domains)

    ~H"""
    <div class="card bg-base-100 shadow-md">
      <div class="card-body">
        <div class="flex justify-between items-center">
          <h2 class="card-title">Domains</h2>
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
                  <th>Type</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <%= for domain <- @domains do %>
                  <tr>
                    <td class="font-mono text-sm">
                      <a href={"https://#{domain["domain"]}"} target="_blank" class="link link-primary">
                        {domain["domain"]}
                      </a>
                    </td>
                    <td>
                      <span class={[
                        "badge badge-sm",
                        domain["type"] == "PRIMARY" && "badge-primary",
                        domain["type"] == "ALIAS" && "badge-secondary"
                      ]}>
                        {domain["type"]}
                      </span>
                    </td>
                    <td>
                      <button
                        class="btn btn-ghost btn-xs text-error"
                        phx-click="delete_domain"
                        phx-value-domain={domain["domain"]}
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

          <div class="form-control">
            <label class="label">
              <span class="label-text">Type</span>
            </label>
            <select name="type" class="select select-bordered">
              <option value="PRIMARY" selected={@type == "PRIMARY"}>Primary</option>
              <option value="ALIAS" selected={@type == "ALIAS"}>Alias</option>
            </select>
            <label class="label">
              <span class="label-text-alt">Primary is the main domain, Alias redirects to Primary</span>
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

  defp env_vars_card(assigns) do
    app_envs = get_in(assigns.app, ["spec", "envs"]) || []
    services = get_in(assigns.app, ["spec", "services"]) || []
    jobs = get_in(assigns.app, ["spec", "jobs"]) || []

    assigns =
      assigns
      |> assign(:app_envs, app_envs)
      |> assign(:services, services)
      |> assign(:jobs, jobs)

    ~H"""
    <div class="card bg-base-100 shadow-md">
      <div class="card-body">
        <div class="flex justify-between items-center">
          <h2 class="card-title">Environment Variables</h2>
          <button class="btn btn-primary btn-sm" phx-click="open_add_env_modal">
            <.icon name="hero-plus" class="h-4 w-4" /> Add Variable
          </button>
        </div>

        <%= if @app_envs != [] do %>
          <div class="mb-4">
            <h3 class="font-medium text-sm text-base-content/60 mb-2">App-level</h3>
            <.env_table envs={@app_envs} editable={true} />
          </div>
        <% end %>

        <%= for service <- @services do %>
          <%= if service["envs"] && service["envs"] != [] do %>
            <div class="mb-4">
              <h3 class="font-medium text-sm text-base-content/60 mb-2">
                Service: {service["name"]}
              </h3>
              <.env_table envs={service["envs"]} editable={false} />
            </div>
          <% end %>
        <% end %>

        <%= for job <- @jobs do %>
          <%= if job["envs"] && job["envs"] != [] do %>
            <div class="mb-4">
              <h3 class="font-medium text-sm text-base-content/60 mb-2">
                Job: {job["name"]}
              </h3>
              <.env_table envs={job["envs"]} editable={false} />
            </div>
          <% end %>
        <% end %>

        <%= if @app_envs == [] && Enum.all?(@services, &(is_nil(&1["envs"]) || &1["envs"] == [])) && Enum.all?(@jobs, &(is_nil(&1["envs"]) || &1["envs"] == [])) do %>
          <p class="text-base-content/60">No environment variables configured</p>
        <% end %>
      </div>
    </div>
    """
  end

  defp env_table(assigns) do
    assigns = assign_new(assigns, :editable, fn -> false end)

    ~H"""
    <div class="overflow-x-auto">
      <table class="table table-sm">
        <thead>
          <tr>
            <th>Key</th>
            <th>Value</th>
            <th>Scope</th>
            <th>Type</th>
            <th :if={@editable}></th>
          </tr>
        </thead>
        <tbody>
          <%= for env <- @envs do %>
            <tr>
              <td class="font-mono text-sm">{env["key"]}</td>
              <td class="font-mono text-sm max-w-xs truncate">
                <%= if env["type"] == "SECRET" do %>
                  <span class="text-base-content/40">••••••••</span>
                <% else %>
                  {env["value"] || env["key"]}
                <% end %>
              </td>
              <td><span class="badge badge-ghost badge-sm">{env["scope"]}</span></td>
              <td><span class="badge badge-ghost badge-sm">{env["type"] || "GENERAL"}</span></td>
              <td :if={@editable} class="flex gap-1">
                <button
                  class="btn btn-ghost btn-xs"
                  phx-click="open_edit_env_modal"
                  phx-value-key={env["key"]}
                >
                  <.icon name="hero-pencil" class="h-3 w-3" />
                </button>
                <button
                  class="btn btn-ghost btn-xs text-error"
                  phx-click="delete_env"
                  phx-value-key={env["key"]}
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
          <div class="form-control">
            <label class="label">
              <span class="label-text">Key</span>
            </label>
            <input
              type="text"
              name="key"
              value={@form[:key].value}
              class="input input-bordered"
              placeholder="MY_ENV_VAR"
              required
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
              value={@form[:value].value}
              class="input input-bordered"
              placeholder="value"
            />
          </div>

          <div class="form-control">
            <label class="label">
              <span class="label-text">Type</span>
            </label>
            <select name="type" class="select select-bordered">
              <option value="GENERAL" selected={@form[:type].value == "GENERAL"}>General</option>
              <option value="SECRET" selected={@form[:type].value == "SECRET"}>Secret</option>
            </select>
          </div>

          <div class="form-control">
            <label class="label">
              <span class="label-text">Scope</span>
            </label>
            <select name="scope" class="select select-bordered">
              <option value="RUN_AND_BUILD_TIME" selected={@form[:scope].value == "RUN_AND_BUILD_TIME"}>
                Run and Build Time
              </option>
              <option value="RUN_TIME" selected={@form[:scope].value == "RUN_TIME"}>
                Run Time Only
              </option>
              <option value="BUILD_TIME" selected={@form[:scope].value == "BUILD_TIME"}>
                Build Time Only
              </option>
            </select>
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
