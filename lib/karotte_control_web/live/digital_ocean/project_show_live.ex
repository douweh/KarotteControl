defmodule KarotteControlWeb.DigitalOcean.ProjectShowLive do
  use KarotteControlWeb, :live_view

  alias KarotteControl.DigitalOcean.{Projects, Apps, Databases, Droplets}
  alias KarotteControl.Dokku.{SSH, Credentials, KeyGenerator}

  @impl true
  def mount(%{"project_id" => project_id}, _session, socket) do
    socket =
      socket
      |> assign(:project_id, project_id)
      |> assign(:project, nil)
      |> assign(:resources, [])
      |> assign(:apps, [])
      |> assign(:databases, [])
      |> assign(:dev_databases, [])
      |> assign(:dokku_droplets, [])
      |> assign(:loading, true)
      |> assign(:error, nil)
      |> assign(:show_ssh_modal, false)
      |> assign(:ssh_modal_droplet, nil)
      |> assign(:ssh_key_input, "")
      |> assign(:ssh_port_input, "443")
      |> assign(:generated_public_key, nil)
      |> assign(:generating_key, false)

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
           {:ok, databases} <- load_databases(resources),
           {:ok, dokku_droplets} <- load_dokku_droplets(resources) do
        # Extract dev databases from app specs
        dev_databases = extract_dev_databases(apps)

        # Trigger async loading of Dokku apps for droplets with credentials
        for droplet <- dokku_droplets, droplet["has_ssh_credentials"] do
          send(self(), {:load_dokku_apps, droplet["id"]})
        end

        socket
        |> assign(:page_title, project["name"])
        |> assign(:project, project)
        |> assign(:resources, resources)
        |> assign(:apps, apps)
        |> assign(:databases, databases)
        |> assign(:dev_databases, dev_databases)
        |> assign(:dokku_droplets, dokku_droplets)
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
  def handle_info({:load_dokku_apps, droplet_id}, socket) do
    dokku_droplets =
      Enum.map(socket.assigns.dokku_droplets, fn droplet ->
        if to_string(droplet["id"]) == to_string(droplet_id) do
          case SSH.list_apps(droplet_id) do
            {:ok, apps} -> Map.put(droplet, "dokku_apps", apps)
            {:error, reason} -> Map.put(droplet, "dokku_apps", {:error, reason})
          end
        else
          droplet
        end
      end)

    {:noreply, assign(socket, :dokku_droplets, dokku_droplets)}
  end

  defp extract_dev_databases(apps) do
    apps
    |> Enum.flat_map(fn app ->
      app_name = get_in(app, ["spec", "name"])
      databases = get_in(app, ["spec", "databases"]) || []

      # Only include dev databases (those without a cluster_name, which means
      # they're App Platform dev databases, not references to managed databases)
      databases
      |> Enum.filter(fn db -> is_nil(db["cluster_name"]) end)
      |> Enum.map(fn db ->
        %{
          "name" => db["name"],
          "engine" => db["engine"],
          "version" => db["version"],
          "app_name" => app_name,
          "app_id" => app["id"],
          "type" => "dev"
        }
      end)
    end)
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

  defp load_dokku_droplets(resources) do
    droplet_urns = Projects.extract_urns_by_type(resources, "droplet")

    if droplet_urns == [] do
      {:ok, []}
    else
      # Get all droplets with the "dokku" tag
      case Droplets.list_by_tag("dokku") do
        {:ok, dokku_droplets} ->
          # Filter to only those in this project
          droplet_ids = Enum.map(droplet_urns, &Projects.extract_id_from_urn/1)

          project_dokku_droplets =
            dokku_droplets
            |> Enum.filter(&(to_string(&1["id"]) in droplet_ids))
            |> Enum.map(fn droplet ->
              # Check if we have SSH credentials and mark for async loading
              has_creds = Credentials.has_credentials?(droplet["id"])
              Map.merge(droplet, %{"has_ssh_credentials" => has_creds, "dokku_apps" => :loading})
            end)

          {:ok, project_dokku_droplets}

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
          <div class="flex gap-2">
            <.link navigate={~p"/digitalocean/projects/#{@project_id}/apps/new"} class="btn btn-success btn-sm">
              <.icon name="hero-plus" class="h-4 w-4 mr-1" /> Create App
            </.link>
            <button phx-click="refresh" class="btn btn-primary btn-sm">
              <.icon name="hero-arrow-path" class="h-4 w-4 mr-1" /> Refresh
            </button>
          </div>
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
                Databases ({length(@databases) + length(@dev_databases)})
              </h2>
              <%= if @databases == [] and @dev_databases == [] do %>
                <p class="text-base-content/60">No databases in this project</p>
              <% else %>
                <div class="space-y-3">
                  <%= for db <- @databases do %>
                    <.database_item db={db} />
                  <% end %>
                  <%= for db <- @dev_databases do %>
                    <.dev_database_item db={db} />
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>
        </div>

        <%= for droplet <- @dokku_droplets do %>
          <.dokku_droplet_card droplet={droplet} />
        <% end %>

        <%= if has_other_resources?(@resources, @dokku_droplets) do %>
          <div class="card bg-base-100 shadow-md">
            <div class="card-body">
              <h2 class="card-title">
                <.icon name="hero-cube" class="h-5 w-5" />
                Other Resources
              </h2>
              <div class="space-y-2">
                <%= for resource <- other_resources(@resources, @dokku_droplets) do %>
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

      <.ssh_key_modal
        :if={@show_ssh_modal}
        droplet={@ssh_modal_droplet}
        ssh_key_input={@ssh_key_input}
        ssh_port_input={@ssh_port_input}
        generated_public_key={@generated_public_key}
        generating_key={@generating_key}
      />
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

  defp dev_database_item(assigns) do
    ~H"""
    <div class="flex items-center justify-between p-3 bg-base-200 rounded-lg">
      <div>
        <div class="font-medium">
          {@db["name"]}
          <span class="badge badge-info badge-xs ml-2">dev</span>
        </div>
        <div class="text-sm text-base-content/60">
          {@db["engine"]} {@db["version"]} · via {@db["app_name"]}
        </div>
      </div>
      <.link navigate={~p"/digitalocean/apps/#{@db["app_id"]}"} class="btn btn-sm btn-ghost">
        <.icon name="hero-arrow-right" class="h-4 w-4" />
      </.link>
    </div>
    """
  end

  defp dokku_droplet_card(assigns) do
    {app_count, error_message} =
      case assigns.droplet["dokku_apps"] do
        apps when is_list(apps) -> {length(apps), nil}
        {:error, reason} -> {0, format_ssh_error(reason)}
        _ -> {0, nil}
      end

    assigns =
      assigns
      |> assign(:app_count, app_count)
      |> assign(:error_message, error_message)

    ~H"""
    <div class="card bg-base-100 shadow-md">
      <div class="card-body">
        <div class="flex justify-between items-center">
          <h2 class="card-title">
            <.icon name="hero-server" class="h-5 w-5" />
            Dokku Apps on {@droplet["name"]} ({@app_count})
          </h2>
          <%= if not @droplet["has_ssh_credentials"] do %>
            <button
              class="btn btn-warning btn-sm"
              phx-click="open_ssh_modal"
              phx-value-droplet-id={@droplet["id"]}
            >
              <.icon name="hero-key" class="h-4 w-4" /> Add SSH Key
            </button>
          <% else %>
            <div class="flex gap-2">
              <.link
                navigate={~p"/digitalocean/dokku/#{@droplet["id"]}/apps/new"}
                class="btn btn-primary btn-sm"
              >
                <.icon name="hero-plus" class="h-4 w-4" /> Create App
              </.link>
              <button
                class="btn btn-ghost btn-sm"
                phx-click="refresh_dokku_apps"
                phx-value-droplet-id={@droplet["id"]}
              >
                <.icon name="hero-arrow-path" class="h-4 w-4" />
              </button>
            </div>
          <% end %>
        </div>

        <%= cond do %>
          <% not @droplet["has_ssh_credentials"] -> %>
            <div class="alert alert-warning">
              <.icon name="hero-exclamation-triangle" class="h-5 w-5" />
              <span>SSH credentials required to manage Dokku apps. Click "Add SSH Key" to configure.</span>
            </div>
          <% @droplet["dokku_apps"] == :loading -> %>
            <div class="flex justify-center py-4">
              <span class="loading loading-spinner loading-md"></span>
            </div>
          <% @error_message -> %>
            <div class="alert alert-error">
              <.icon name="hero-exclamation-circle" class="h-5 w-5" />
              <div class="flex-1">
                <div class="font-medium">Failed to load Dokku apps</div>
                <div class="text-sm opacity-80 font-mono whitespace-pre-wrap">{@error_message}</div>
              </div>
              <button
                class="btn btn-sm btn-ghost"
                phx-click="open_ssh_modal"
                phx-value-droplet-id={@droplet["id"]}
              >
                <.icon name="hero-key" class="h-4 w-4" /> Reconfigure
              </button>
            </div>
          <% is_list(@droplet["dokku_apps"]) and @droplet["dokku_apps"] == [] -> %>
            <p class="text-base-content/60">No Dokku apps on this droplet</p>
          <% is_list(@droplet["dokku_apps"]) -> %>
            <div class="space-y-3">
              <%= for app_name <- @droplet["dokku_apps"] do %>
                <.dokku_app_item droplet_id={@droplet["id"]} app_name={app_name} />
              <% end %>
            </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp dokku_app_item(assigns) do
    ~H"""
    <div class="flex items-center justify-between p-3 bg-base-200 rounded-lg">
      <div>
        <div class="font-medium">{@app_name}</div>
        <div class="text-sm text-base-content/60">
          Dokku app
        </div>
      </div>
      <.link navigate={~p"/digitalocean/dokku/#{@droplet_id}/apps/#{@app_name}"} class="btn btn-sm btn-ghost">
        <.icon name="hero-arrow-right" class="h-4 w-4" />
      </.link>
    </div>
    """
  end

  defp ssh_key_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-3xl">
        <h3 class="font-bold text-lg">Add SSH Key for {@droplet["name"]}</h3>

        <%= if @generated_public_key do %>
          <!-- Step 2: Show instructions after key generation -->
          <div class="space-y-4 mt-4">
            <div class="alert alert-success">
              <.icon name="hero-check-circle" class="h-5 w-5" />
              <span>SSH key pair generated! Follow the steps below to add it to your droplet.</span>
            </div>

            <div class="bg-base-200 p-4 rounded-lg space-y-3">
              <h4 class="font-semibold">Step 1: Access your droplet console</h4>
              <p class="text-sm text-base-content/70">
                Go to DigitalOcean Dashboard → Droplets → {@droplet["name"]} → Access → Launch Droplet Console
              </p>
            </div>

            <div class="bg-base-200 p-4 rounded-lg space-y-3">
              <h4 class="font-semibold">Step 2: Add the public key to authorized_keys</h4>
              <p class="text-sm text-base-content/70">Run this command in the console:</p>
              <div class="mockup-code text-xs">
                <pre><code>echo '{@generated_public_key}' >> ~/.ssh/authorized_keys</code></pre>
              </div>
              <button
                type="button"
                class="btn btn-ghost btn-xs"
                phx-click={JS.dispatch("phx:copy", to: "#public-key-copy")}
                onclick={"navigator.clipboard.writeText(document.getElementById('public-key-command').textContent)"}
              >
                <.icon name="hero-clipboard" class="h-4 w-4" /> Copy command
              </button>
              <input type="hidden" id="public-key-command" value={"echo '#{@generated_public_key}' >> ~/.ssh/authorized_keys"} />
            </div>

            <div class="bg-base-200 p-4 rounded-lg space-y-3">
              <h4 class="font-semibold">Step 3: Verify permissions (if needed)</h4>
              <div class="mockup-code text-xs">
                <pre><code>chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys</code></pre>
              </div>
            </div>

            <div class="bg-base-200 p-4 rounded-lg space-y-3">
              <h4 class="font-semibold">Step 4: Enable SSH on port 443 (required for App Platform)</h4>
              <p class="text-sm text-base-content/70">Port 22 is blocked. Add port 443 to SSH config:</p>
              <div class="mockup-code text-xs">
                <pre><code>echo "Port 443" | sudo tee -a /etc/ssh/sshd_config && sudo systemctl restart ssh</code></pre>
              </div>
            </div>

            <form phx-submit="save_ssh_key" phx-change="update_ssh_key_input">
              <input type="hidden" name="droplet_id" value={@droplet["id"]} />
              <input type="hidden" name="droplet_name" value={@droplet["name"]} />
              <input type="hidden" name="ssh_key" value={@ssh_key_input} />

              <div class="form-control mt-4">
                <label class="label">
                  <span class="label-text">SSH Port</span>
                </label>
                <input
                  type="number"
                  name="ssh_port"
                  value={@ssh_port_input}
                  class="input input-bordered w-32"
                  min="1"
                  max="65535"
                />
                <label class="label">
                  <span class="label-text-alt">Port 22 is blocked on App Platform. Use 443 or another port.</span>
                </label>
              </div>

              <div class="modal-action">
                <button type="button" class="btn" phx-click="close_ssh_modal">Cancel</button>
                <button type="submit" class="btn btn-primary">
                  I've added the key - Save & Connect
                </button>
              </div>
            </form>
          </div>
        <% else %>
          <!-- Step 1: Generate or paste key -->
          <div class="space-y-4 mt-4">
            <div class="flex gap-4">
              <button
                type="button"
                class="btn btn-primary flex-1"
                phx-click="generate_ssh_key"
                disabled={@generating_key}
              >
                <%= if @generating_key do %>
                  <span class="loading loading-spinner loading-sm"></span>
                  Generating...
                <% else %>
                  <.icon name="hero-sparkles" class="h-4 w-4" />
                  Generate New Key Pair
                <% end %>
              </button>
            </div>

            <div class="divider">OR paste existing key</div>

            <form phx-submit="save_ssh_key" phx-change="update_ssh_key_input">
              <input type="hidden" name="droplet_id" value={@droplet["id"]} />
              <input type="hidden" name="droplet_name" value={@droplet["name"]} />

              <div class="form-control">
                <label class="label">
                  <span class="label-text">Private SSH Key</span>
                </label>
                <textarea
                  name="ssh_key"
                  class="textarea textarea-bordered h-48 font-mono text-xs"
                  placeholder="-----BEGIN OPENSSH PRIVATE KEY-----&#10;...&#10;-----END OPENSSH PRIVATE KEY-----"
                >{@ssh_key_input}</textarea>
                <label class="label">
                  <span class="label-text-alt">Paste a private key that already has access to this droplet</span>
                </label>
              </div>

              <div class="form-control">
                <label class="label">
                  <span class="label-text">SSH Port</span>
                </label>
                <input
                  type="number"
                  name="ssh_port"
                  value={@ssh_port_input}
                  class="input input-bordered w-32"
                  min="1"
                  max="65535"
                />
                <label class="label">
                  <span class="label-text-alt">Port 22 is blocked on App Platform. Use 443 or another port.</span>
                </label>
              </div>

              <div class="modal-action">
                <button type="button" class="btn" phx-click="close_ssh_modal">Cancel</button>
                <button type="submit" class="btn btn-primary" disabled={@ssh_key_input == ""}>
                  Save Existing Key
                </button>
              </div>
            </form>
          </div>
        <% end %>
      </div>
      <div class="modal-backdrop" phx-click="close_ssh_modal"></div>
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

  defp has_other_resources?(resources, dokku_droplets) do
    other_resources(resources, dokku_droplets) != []
  end

  defp other_resources(resources, dokku_droplets) do
    dokku_droplet_ids = Enum.map(dokku_droplets, &to_string(&1["id"]))

    Enum.reject(resources, fn r ->
      urn = r["urn"]

      cond do
        String.starts_with?(urn, "do:app:") -> true
        String.starts_with?(urn, "do:dbaas:") -> true
        String.starts_with?(urn, "do:droplet:") ->
          droplet_id = Projects.extract_id_from_urn(urn)
          droplet_id in dokku_droplet_ids
        true -> false
      end
    end)
  end

  defp resource_type(urn) do
    case String.split(urn, ":") do
      ["do", type | _] -> type
      _ -> "unknown"
    end
  end

  defp format_ssh_error(reason) when is_binary(reason) do
    reason
    |> String.trim()
    |> String.slice(0, 500)
  end

  defp format_ssh_error(:no_credentials), do: "No SSH credentials configured"
  defp format_ssh_error(:no_public_ip), do: "Droplet has no public IP address"
  defp format_ssh_error(reason), do: inspect(reason)

  @impl true
  def handle_event("refresh", _params, socket) do
    socket =
      socket
      |> assign(:loading, true)
      |> assign(:error, nil)

    send(self(), :load_project)
    {:noreply, socket}
  end

  def handle_event("open_ssh_modal", %{"droplet-id" => droplet_id}, socket) do
    droplet = Enum.find(socket.assigns.dokku_droplets, &(to_string(&1["id"]) == droplet_id))

    {:noreply,
     socket
     |> assign(:show_ssh_modal, true)
     |> assign(:ssh_modal_droplet, droplet)
     |> assign(:ssh_key_input, "")
     |> assign(:ssh_port_input, "443")
     |> assign(:generated_public_key, nil)
     |> assign(:generating_key, false)}
  end

  def handle_event("close_ssh_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_ssh_modal, false)
     |> assign(:ssh_modal_droplet, nil)
     |> assign(:ssh_key_input, "")
     |> assign(:ssh_port_input, "443")
     |> assign(:generated_public_key, nil)
     |> assign(:generating_key, false)}
  end

  def handle_event("generate_ssh_key", _params, socket) do
    socket = assign(socket, :generating_key, true)

    case KeyGenerator.generate_key_pair() do
      {:ok, %{private_key: private_key, public_key: public_key}} ->
        {:noreply,
         socket
         |> assign(:ssh_key_input, private_key)
         |> assign(:generated_public_key, public_key)
         |> assign(:generating_key, false)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:generating_key, false)
         |> put_flash(:error, "Failed to generate key: #{reason}")}
    end
  end

  def handle_event("update_ssh_key_input", params, socket) do
    socket =
      socket
      |> maybe_assign(:ssh_key_input, params["ssh_key"])
      |> maybe_assign(:ssh_port_input, params["ssh_port"])

    {:noreply, socket}
  end

  defp maybe_assign(socket, _key, nil), do: socket
  defp maybe_assign(socket, key, value), do: assign(socket, key, value)

  def handle_event("save_ssh_key", %{"droplet_id" => droplet_id, "droplet_name" => droplet_name, "ssh_key" => ssh_key} = params, socket) do
    ssh_port = params["ssh_port"] || socket.assigns.ssh_port_input || "443"

    case Credentials.upsert(%{
      droplet_id: droplet_id,
      droplet_name: droplet_name,
      ssh_private_key: ssh_key,
      ssh_port: String.to_integer(ssh_port)
    }) do
      {:ok, _credential} ->
        # Update the droplet to show it has credentials and trigger app loading
        dokku_droplets =
          Enum.map(socket.assigns.dokku_droplets, fn droplet ->
            if to_string(droplet["id"]) == droplet_id do
              droplet
              |> Map.put("has_ssh_credentials", true)
              |> Map.put("dokku_apps", :loading)
            else
              droplet
            end
          end)

        # Trigger async loading of Dokku apps
        send(self(), {:load_dokku_apps, droplet_id})

        {:noreply,
         socket
         |> assign(:dokku_droplets, dokku_droplets)
         |> assign(:show_ssh_modal, false)
         |> assign(:ssh_modal_droplet, nil)
         |> assign(:ssh_key_input, "")
         |> put_flash(:info, "SSH key saved. Loading Dokku apps...")}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to save SSH key: #{inspect(changeset.errors)}")}
    end
  end

  def handle_event("refresh_dokku_apps", %{"droplet-id" => droplet_id}, socket) do
    # Set loading state for this droplet
    dokku_droplets =
      Enum.map(socket.assigns.dokku_droplets, fn droplet ->
        if to_string(droplet["id"]) == droplet_id do
          Map.put(droplet, "dokku_apps", :loading)
        else
          droplet
        end
      end)

    send(self(), {:load_dokku_apps, droplet_id})
    {:noreply, assign(socket, :dokku_droplets, dokku_droplets)}
  end
end
