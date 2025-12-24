defmodule KarotteControlWeb.DigitalOcean.DokkuAppNewLive do
  use KarotteControlWeb, :live_view

  alias KarotteControl.DigitalOcean.{Client, Registry, Droplets, Databases}
  alias KarotteControl.Dokku.{Deployments, SSH}

  @impl true
  def mount(%{"droplet_id" => droplet_id}, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Create Dokku App")
      |> assign(:droplet_id, droplet_id)
      |> assign(:droplet, nil)
      |> assign(:step, 1)
      |> assign(:loading, true)
      |> assign(:creating, false)
      |> assign(:create_status, nil)
      |> assign(:error, nil)
      # Step 1: Basic info
      |> assign(:app_name, "")
      |> assign(:http_port, "4000")
      # Step 2: Container image
      |> assign(:registry, nil)
      |> assign(:repositories, [])
      |> assign(:selected_repo, nil)
      |> assign(:tags, [])
      |> assign(:selected_tag, nil)
      |> assign(:auto_deploy, true)
      # Step 3: Database
      |> assign(:database_type, "none")
      |> assign(:managed_databases, [])
      |> assign(:selected_database, nil)
      # Step 4: Environment variables
      |> assign(:env_vars, [])
      |> assign(:new_env_key, "")
      |> assign(:new_env_value, "")
      |> assign(:new_env_type, "GENERAL")
      # Deploy output
      |> assign(:deploy_output, nil)
      |> assign(:deploy_success, false)

    if connected?(socket) do
      send(self(), :load_initial_data)
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:load_initial_data, socket) do
    droplet_id = socket.assigns.droplet_id

    socket =
      with {:ok, droplet} <- Droplets.get(droplet_id),
           {:ok, registry} <- Registry.get(),
           {:ok, repositories} <- Registry.list_repositories(registry["name"]),
           {:ok, databases} <- Databases.list() do
        socket
        |> assign(:page_title, "Create Dokku App on #{droplet["name"]}")
        |> assign(:droplet, droplet)
        |> assign(:registry, registry)
        |> assign(:repositories, repositories)
        |> assign(:managed_databases, databases)
        |> assign(:loading, false)
      else
        {:error, reason} ->
          socket
          |> assign(:error, "Failed to load data: #{inspect(reason)}")
          |> assign(:loading, false)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info(:load_tags, socket) do
    registry_name = socket.assigns.registry["name"]
    repo_name = socket.assigns.selected_repo

    socket =
      case Registry.list_tags(registry_name, repo_name) do
        {:ok, tags} ->
          sorted_tags = Enum.sort_by(tags, & &1["updated_at"], :desc)
          latest_tag = if sorted_tags != [], do: hd(sorted_tags)["tag"], else: nil

          socket
          |> assign(:tags, sorted_tags)
          |> assign(:selected_tag, latest_tag)

        {:error, _} ->
          assign(socket, :tags, [])
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info(:do_create_app, socket) do
    if socket.assigns.database_type == "managed" do
      send(self(), {:create_step, :create_db_user})
    else
      send(self(), {:create_step, :create_app})
    end

    {:noreply, socket}
  end

  # Database setup steps for managed databases
  def handle_info({:create_step, :create_db_user}, socket) do
    socket = assign(socket, :create_status, "Creating database user...")

    db = Enum.find(socket.assigns.managed_databases, &(&1["id"] == socket.assigns.selected_database))
    result = Databases.create_user(db["id"], socket.assigns.app_name)

    user_ok =
      case result do
        {:ok, _user} -> true
        {:error, {409, _}} -> true
        {:error, {422, _}} -> true
        _ -> false
      end

    if user_ok do
      send(self(), {:create_step, :create_db})
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:creating, false)
       |> assign(:create_status, nil)
       |> put_flash(:error, "Failed to create database user: #{inspect(result)}")}
    end
  end

  def handle_info({:create_step, :create_db}, socket) do
    socket = assign(socket, :create_status, "Creating database...")

    db = Enum.find(socket.assigns.managed_databases, &(&1["id"] == socket.assigns.selected_database))
    db_name = "db_#{String.replace(socket.assigns.app_name, "-", "_")}"
    result = Databases.create_db(db["id"], db_name)

    db_ok =
      case result do
        {:ok, _db} -> true
        {:error, {409, _}} -> true
        {:error, {422, _}} -> true
        _ -> false
      end

    if db_ok do
      send(self(), {:create_step, :grant_privileges})
      {:noreply, assign(socket, :db_name, db_name)}
    else
      {:noreply,
       socket
       |> assign(:creating, false)
       |> assign(:create_status, nil)
       |> put_flash(:error, "Failed to create database: #{inspect(result)}")}
    end
  end

  def handle_info({:create_step, :grant_privileges}, socket) do
    socket = assign(socket, :create_status, "Granting database privileges...")

    db = Enum.find(socket.assigns.managed_databases, &(&1["id"] == socket.assigns.selected_database))
    db_name = socket.assigns.db_name
    username = socket.assigns.app_name

    case Databases.get(db["id"]) do
      {:ok, cluster} ->
        case Databases.grant_privileges(cluster, db_name, username) do
          :ok ->
            send(self(), {:create_step, :add_trusted_source})
            {:noreply, assign(socket, :cluster, cluster)}

          {:error, error} ->
            {:noreply,
             socket
             |> assign(:creating, false)
             |> assign(:create_status, nil)
             |> put_flash(:error, "Failed to grant privileges: #{inspect(error)}")}
        end

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:creating, false)
         |> assign(:create_status, nil)
         |> put_flash(:error, "Failed to fetch database details: #{inspect(reason)}")}
    end
  end

  def handle_info({:create_step, :add_trusted_source}, socket) do
    socket = assign(socket, :create_status, "Adding droplet to database trusted sources...")

    db = Enum.find(socket.assigns.managed_databases, &(&1["id"] == socket.assigns.selected_database))
    Databases.add_droplet_to_trusted_sources(db["id"], socket.assigns.droplet_id)

    send(self(), {:create_step, :fetch_db_credentials})
    {:noreply, socket}
  end

  def handle_info({:create_step, :fetch_db_credentials}, socket) do
    socket = assign(socket, :create_status, "Fetching database credentials...")

    db = Enum.find(socket.assigns.managed_databases, &(&1["id"] == socket.assigns.selected_database))
    username = socket.assigns.app_name

    case Databases.get_user(db["id"], username) do
      {:ok, user} ->
        cluster = socket.assigns.cluster
        db_name = socket.assigns.db_name
        password = user["password"]

        database_url = Databases.build_database_url(cluster, db_name, username, password)

        send(self(), {:create_step, :create_app})
        {:noreply, assign(socket, :database_url, database_url)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:creating, false)
         |> assign(:create_status, nil)
         |> put_flash(:error, "Failed to fetch database credentials: #{inspect(reason)}")}
    end
  end

  def handle_info({:create_step, :create_app}, socket) do
    socket = assign(socket, :create_status, "Creating Dokku app...")

    case SSH.create_app(socket.assigns.droplet_id, socket.assigns.app_name) do
      {:ok, _} ->
        send(self(), {:create_step, :set_env_vars})
        {:noreply, socket}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:creating, false)
         |> assign(:create_status, nil)
         |> put_flash(:error, "Failed to create app: #{inspect(reason)}")}
    end
  end

  def handle_info({:create_step, :set_env_vars}, socket) do
    socket = assign(socket, :create_status, "Setting environment variables...")

    # Build env vars map
    env_map =
      socket.assigns.env_vars
      |> Enum.map(fn env -> {env["key"], env["value"]} end)
      |> Map.new()

    # Add SECRET_KEY_BASE if not provided
    env_map =
      if Map.has_key?(env_map, "SECRET_KEY_BASE") do
        env_map
      else
        secret_key_base = :crypto.strong_rand_bytes(64) |> Base.encode64() |> binary_part(0, 64)
        Map.put(env_map, "SECRET_KEY_BASE", secret_key_base)
      end

    # Add PHX_HOST based on app name (can be updated later)
    env_map =
      if Map.has_key?(env_map, "PHX_HOST") do
        env_map
      else
        Map.put(env_map, "PHX_HOST", "#{socket.assigns.app_name}.example.com")
      end

    # Add DATABASE_URL if using managed database
    env_map =
      if socket.assigns[:database_url] do
        Map.put(env_map, "DATABASE_URL", socket.assigns.database_url)
      else
        env_map
      end

    case SSH.set_env_vars(socket.assigns.droplet_id, socket.assigns.app_name, env_map) do
      {:ok, _} ->
        send(self(), {:create_step, :set_port})
        {:noreply, socket}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:creating, false)
         |> assign(:create_status, nil)
         |> put_flash(:error, "Failed to set environment variables: #{inspect(reason)}")}
    end
  end

  def handle_info({:create_step, :set_port}, socket) do
    socket = assign(socket, :create_status, "Configuring port...")

    case SSH.set_port(
           socket.assigns.droplet_id,
           socket.assigns.app_name,
           80,
           String.to_integer(socket.assigns.http_port)
         ) do
      {:ok, _} ->
        send(self(), {:create_step, :docker_login})
        {:noreply, socket}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:creating, false)
         |> assign(:create_status, nil)
         |> put_flash(:error, "Failed to set port: #{inspect(reason)}")}
    end
  end

  def handle_info({:create_step, :docker_login}, socket) do
    socket = assign(socket, :create_status, "Authenticating with container registry...")

    # For DigitalOcean registry, username and password are both the API token
    api_token = Client.get_api_token()

    case SSH.registry_login(socket.assigns.droplet_id, "registry.digitalocean.com", api_token, api_token) do
      {:ok, _} ->
        send(self(), {:create_step, :deploy})
        {:noreply, socket}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:creating, false)
         |> assign(:create_status, nil)
         |> put_flash(:error, "Failed to authenticate with registry: #{inspect(reason)}")}
    end
  end

  def handle_info({:create_step, :deploy}, socket) do
    socket = assign(socket, :create_status, "Deploying from registry (this may take a few minutes)...")

    registry_name = socket.assigns.registry["name"]
    image_url = "registry.digitalocean.com/#{registry_name}/#{socket.assigns.selected_repo}:#{socket.assigns.selected_tag}"

    case SSH.deploy_from_image(socket.assigns.droplet_id, socket.assigns.app_name, image_url) do
      {:ok, output} ->
        # Save deployment config for auto-deploy
        {:ok, deployment} = Deployments.link_image(
          socket.assigns.droplet_id,
          socket.assigns.app_name,
          registry_name,
          socket.assigns.selected_repo,
          tag: socket.assigns.selected_tag,
          auto_deploy: socket.assigns.auto_deploy
        )

        # Get the current digest from tags and save it to prevent immediate re-deploy
        digest = get_current_digest(socket.assigns.tags, socket.assigns.selected_tag)
        if digest, do: Deployments.update_digest(deployment, digest, "success")

        {:noreply,
         socket
         |> assign(:creating, false)
         |> assign(:create_status, nil)
         |> assign(:deploy_output, output)
         |> assign(:deploy_success, true)}

      {:error, reason} ->
        output = if is_binary(reason), do: reason, else: inspect(reason)

        {:noreply,
         socket
         |> assign(:creating, false)
         |> assign(:create_status, nil)
         |> assign(:deploy_output, output)
         |> assign(:deploy_success, false)}
    end
  end

  @impl true
  def handle_event("update_field", params, socket) do
    socket =
      cond do
        Map.has_key?(params, "field") and Map.has_key?(params, "value") ->
          field = params["field"]
          value = params["value"]

          case field do
            "app_name" -> assign(socket, :app_name, value)
            "http_port" -> assign(socket, :http_port, value)
            "database_type" -> assign(socket, :database_type, value)
            "selected_database" -> assign(socket, :selected_database, value)
            "auto_deploy" -> assign(socket, :auto_deploy, value == "true")
            _ -> socket
          end

        true ->
          socket
          |> maybe_assign(:database_type, params["database_type"])
          |> maybe_assign(:selected_database, params["selected_database"])
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("update_new_env", params, socket) do
    socket =
      socket
      |> maybe_assign(:new_env_key, params["key"])
      |> maybe_assign(:new_env_value, params["value"])
      |> maybe_assign(:new_env_type, params["type"])

    {:noreply, socket}
  end

  @impl true
  def handle_event("add_env_var", _params, socket) do
    key = String.trim(socket.assigns.new_env_key)
    value = socket.assigns.new_env_value
    type = socket.assigns.new_env_type

    if key != "" do
      new_env = %{"key" => key, "value" => value, "type" => type}
      env_vars = socket.assigns.env_vars ++ [new_env]

      {:noreply,
       socket
       |> assign(:env_vars, env_vars)
       |> assign(:new_env_key, "")
       |> assign(:new_env_value, "")
       |> assign(:new_env_type, "GENERAL")}
    else
      {:noreply, put_flash(socket, :error, "Environment variable key is required")}
    end
  end

  @impl true
  def handle_event("remove_env_var", %{"key" => key}, socket) do
    env_vars = Enum.reject(socket.assigns.env_vars, &(&1["key"] == key))
    {:noreply, assign(socket, :env_vars, env_vars)}
  end

  @impl true
  def handle_event("select_repo", %{"repo" => repo_name}, socket) do
    socket =
      socket
      |> assign(:selected_repo, repo_name)
      |> assign(:tags, [])
      |> assign(:selected_tag, nil)

    send(self(), :load_tags)
    {:noreply, socket}
  end

  @impl true
  def handle_event("select_tag", %{"tag" => tag}, socket) do
    {:noreply, assign(socket, :selected_tag, tag)}
  end

  @impl true
  def handle_event("next_step", _params, socket) do
    current_step = socket.assigns.step

    case validate_step(socket, current_step) do
      :ok ->
        {:noreply, assign(socket, :step, current_step + 1)}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  @impl true
  def handle_event("prev_step", _params, socket) do
    {:noreply, assign(socket, :step, max(1, socket.assigns.step - 1))}
  end

  @impl true
  def handle_event("create_app", _params, socket) do
    socket =
      socket
      |> assign(:creating, true)
      |> assign(:create_status, "Starting...")

    send(self(), :do_create_app)
    {:noreply, socket}
  end

  defp validate_step(socket, step) do
    case step do
      1 ->
        cond do
          String.trim(socket.assigns.app_name) == "" ->
            {:error, "App name is required"}

          not Regex.match?(~r/^[a-z][a-z0-9-]*[a-z0-9]$/, socket.assigns.app_name) ->
            {:error, "App name must be lowercase letters, numbers, and hyphens"}

          true ->
            :ok
        end

      2 ->
        cond do
          is_nil(socket.assigns.selected_repo) ->
            {:error, "Please select a repository"}

          is_nil(socket.assigns.selected_tag) ->
            {:error, "Please select a tag"}

          true ->
            :ok
        end

      3 ->
        case socket.assigns.database_type do
          "managed" when socket.assigns.selected_database in [nil, ""] ->
            {:error, "Please select a managed database"}

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp maybe_assign(socket, _key, nil), do: socket
  defp maybe_assign(socket, key, value), do: assign(socket, key, value)

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
      <% else %>
        <%= if @error do %>
          <div role="alert" class="alert alert-error">
            <.icon name="hero-exclamation-circle" class="h-5 w-5" />
            <span>{@error}</span>
          </div>
        <% else %>
          <.flash kind={:info} flash={@flash} />
          <.flash kind={:error} flash={@flash} />

          <!-- Progress steps -->
          <ul class="steps w-full mb-8">
            <li class={if @step >= 1, do: "step step-primary", else: "step"}>Basic Info</li>
            <li class={if @step >= 2, do: "step step-primary", else: "step"}>Container</li>
            <li class={if @step >= 3, do: "step step-primary", else: "step"}>Database</li>
            <li class={if @step >= 4, do: "step step-primary", else: "step"}>Env Vars</li>
            <li class={if @step >= 5, do: "step step-primary", else: "step"}>Review</li>
          </ul>

          <div class="card bg-base-100 shadow-md">
            <div class="card-body">
              <%= case @step do %>
                <% 1 -> %>
                  <.step_basic_info app_name={@app_name} http_port={@http_port} />
                <% 2 -> %>
                  <.step_container
                    registry={@registry}
                    repositories={@repositories}
                    selected_repo={@selected_repo}
                    tags={@tags}
                    selected_tag={@selected_tag}
                    auto_deploy={@auto_deploy}
                  />
                <% 3 -> %>
                  <.step_database
                    database_type={@database_type}
                    managed_databases={@managed_databases}
                    selected_database={@selected_database}
                  />
                <% 4 -> %>
                  <.step_env_vars
                    env_vars={@env_vars}
                    new_env_key={@new_env_key}
                    new_env_value={@new_env_value}
                    new_env_type={@new_env_type}
                  />
                <% 5 -> %>
                  <%= if @deploy_output do %>
                    <.deploy_result
                      deploy_output={@deploy_output}
                      deploy_success={@deploy_success}
                      app_name={@app_name}
                      droplet_id={@droplet_id}
                    />
                  <% else %>
                    <.step_review
                      app_name={@app_name}
                      http_port={@http_port}
                      registry={@registry}
                      selected_repo={@selected_repo}
                      selected_tag={@selected_tag}
                      auto_deploy={@auto_deploy}
                      database_type={@database_type}
                      managed_databases={@managed_databases}
                      selected_database={@selected_database}
                      env_vars={@env_vars}
                      creating={@creating}
                    />
                  <% end %>
              <% end %>

              <%= if @deploy_output == nil do %>
                <div class="card-actions justify-between mt-6">
                  <%= if @step > 1 do %>
                    <button phx-click="prev_step" class="btn btn-ghost" disabled={@creating}>
                      <.icon name="hero-arrow-left" class="h-4 w-4" /> Back
                    </button>
                  <% else %>
                    <div></div>
                  <% end %>

                  <%= if @step < 5 do %>
                    <button phx-click="next_step" class="btn btn-primary">
                      Next <.icon name="hero-arrow-right" class="h-4 w-4" />
                    </button>
                  <% else %>
                    <div class="flex items-center gap-4">
                      <%= if @create_status do %>
                        <span class="text-sm text-base-content/60">{@create_status}</span>
                      <% end %>
                      <button phx-click="create_app" class="btn btn-success" disabled={@creating}>
                        <%= if @creating do %>
                          <span class="loading loading-spinner loading-sm"></span>
                          Creating...
                        <% else %>
                          <.icon name="hero-rocket-launch" class="h-4 w-4" /> Create App
                        <% end %>
                      </button>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  defp step_basic_info(assigns) do
    ~H"""
    <div class="space-y-4">
      <h2 class="card-title">Basic Information</h2>

      <div class="form-control w-full max-w-md">
        <label class="label">
          <span class="label-text">App Name</span>
        </label>
        <input
          type="text"
          placeholder="my-app"
          class="input input-bordered w-full"
          value={@app_name}
          name="value"
          phx-keyup="update_field"
          phx-value-field="app_name"
        />
        <label class="label">
          <span class="label-text-alt">Lowercase letters, numbers, and hyphens</span>
        </label>
      </div>

      <div class="form-control w-full max-w-md">
        <label class="label">
          <span class="label-text">HTTP Port</span>
        </label>
        <input
          type="number"
          class="input input-bordered w-full"
          value={@http_port}
          phx-blur="update_field"
          phx-value-field="http_port"
        />
        <label class="label">
          <span class="label-text-alt">The port your app listens on (default: 4000 for Phoenix)</span>
        </label>
      </div>
    </div>
    """
  end

  defp step_container(assigns) do
    ~H"""
    <div class="space-y-4">
      <h2 class="card-title">Container Image</h2>
      <p class="text-base-content/60">
        Select an image from your DigitalOcean Container Registry ({@registry["name"]})
      </p>

      <div class="form-control w-full">
        <label class="label">
          <span class="label-text">Repository</span>
        </label>
        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-2">
          <%= for repo <- @repositories do %>
            <button
              type="button"
              phx-click="select_repo"
              phx-value-repo={repo["name"]}
              class={"btn btn-outline justify-start #{if @selected_repo == repo["name"], do: "btn-primary", else: ""}"}
            >
              <.icon name="hero-cube" class="h-4 w-4" />
              {repo["name"]}
            </button>
          <% end %>
        </div>
      </div>

      <%= if @selected_repo do %>
        <div class="form-control w-full">
          <label class="label">
            <span class="label-text">Tag</span>
          </label>
          <%= if @tags == [] do %>
            <div class="flex items-center gap-2 text-base-content/60">
              <span class="loading loading-spinner loading-sm"></span>
              Loading tags...
            </div>
          <% else %>
            <div class="flex flex-wrap gap-2">
              <%= for tag <- Enum.take(@tags, 10) do %>
                <button
                  type="button"
                  phx-click="select_tag"
                  phx-value-tag={tag["tag"]}
                  class={"badge badge-lg cursor-pointer #{if @selected_tag == tag["tag"], do: "badge-primary", else: "badge-outline"}"}
                >
                  {tag["tag"]}
                </button>
              <% end %>
            </div>
          <% end %>
        </div>

        <div class="form-control mt-4">
          <label class="label cursor-pointer justify-start gap-3">
            <input
              type="checkbox"
              class="checkbox checkbox-primary"
              checked={@auto_deploy}
              phx-click="update_field"
              phx-value-field="auto_deploy"
              phx-value-value={if @auto_deploy, do: "false", else: "true"}
            />
            <div>
              <span class="label-text font-medium">Enable auto-deploy</span>
              <p class="text-sm text-base-content/60">
                Automatically deploy when a new image is pushed to this tag
              </p>
            </div>
          </label>
        </div>
      <% end %>
    </div>
    """
  end

  defp step_database(assigns) do
    ~H"""
    <form phx-change="update_field" class="space-y-4">
      <h2 class="card-title">Database Configuration</h2>

      <div class="form-control">
        <label class="label cursor-pointer justify-start gap-4">
          <input
            type="radio"
            name="database_type"
            class="radio radio-primary"
            value="none"
            checked={@database_type == "none"}
            phx-click="update_field"
            phx-value-field="database_type"
            phx-value-value="none"
          />
          <div>
            <span class="label-text font-medium">No Database</span>
            <p class="text-sm text-base-content/60">App doesn't need a database</p>
          </div>
        </label>
      </div>

      <div class="form-control">
        <label class="label cursor-pointer justify-start gap-4">
          <input
            type="radio"
            name="database_type"
            class="radio radio-primary"
            value="managed"
            checked={@database_type == "managed"}
            phx-click="update_field"
            phx-value-field="database_type"
            phx-value-value="managed"
          />
          <div>
            <span class="label-text font-medium">Managed Database</span>
            <p class="text-sm text-base-content/60">Connect to a DigitalOcean managed database cluster</p>
          </div>
        </label>
      </div>

      <%= if @database_type == "managed" do %>
        <div class="ml-10 form-control w-full max-w-md">
          <label class="label">
            <span class="label-text">Select Database</span>
          </label>
          <%= if @managed_databases == [] do %>
            <p class="text-base-content/60">No managed databases available</p>
          <% else %>
            <select
              class="select select-bordered w-full"
              phx-change="update_field"
              name="selected_database"
            >
              <option value="">Select a database...</option>
              <%= for db <- @managed_databases do %>
                <option value={db["id"]} selected={db["id"] == @selected_database}>
                  {db["name"]} ({db["engine"]} {db["version"]})
                </option>
              <% end %>
            </select>
          <% end %>
        </div>
      <% end %>
    </form>
    """
  end

  defp step_env_vars(assigns) do
    ~H"""
    <div class="space-y-4">
      <h2 class="card-title">Environment Variables</h2>
      <p class="text-base-content/60">
        Add custom environment variables for your app. SECRET_KEY_BASE is added automatically.
        DATABASE_URL will be set automatically if you link a database.
      </p>

      <%= if @env_vars != [] do %>
        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Key</th>
                <th>Value</th>
                <th>Type</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <%= for env <- @env_vars do %>
                <tr>
                  <td class="font-mono text-sm">{env["key"]}</td>
                  <td class="font-mono text-sm max-w-xs truncate">
                    <%= if env["type"] == "SECRET" do %>
                      <span class="text-base-content/40">••••••••</span>
                    <% else %>
                      {env["value"]}
                    <% end %>
                  </td>
                  <td><span class="badge badge-ghost badge-sm">{env["type"]}</span></td>
                  <td>
                    <button
                      type="button"
                      class="btn btn-ghost btn-xs text-error"
                      phx-click="remove_env_var"
                      phx-value-key={env["key"]}
                    >
                      <.icon name="hero-trash" class="h-3 w-3" />
                    </button>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      <% end %>

      <div class="bg-base-200 p-4 rounded-lg">
        <h3 class="font-medium mb-3">Add Environment Variable</h3>
        <form phx-change="update_new_env" phx-submit="add_env_var" class="flex flex-wrap gap-3 items-end">
          <div class="form-control">
            <label class="label">
              <span class="label-text">Key</span>
            </label>
            <input
              type="text"
              name="key"
              value={@new_env_key}
              class="input input-bordered input-sm w-48"
              placeholder="MY_ENV_VAR"
            />
          </div>
          <div class="form-control">
            <label class="label">
              <span class="label-text">Value</span>
            </label>
            <input
              type="text"
              name="value"
              value={@new_env_value}
              class="input input-bordered input-sm w-64"
              placeholder="value"
            />
          </div>
          <div class="form-control">
            <label class="label">
              <span class="label-text">Type</span>
            </label>
            <select name="type" class="select select-bordered select-sm">
              <option value="GENERAL" selected={@new_env_type == "GENERAL"}>General</option>
              <option value="SECRET" selected={@new_env_type == "SECRET"}>Secret</option>
            </select>
          </div>
          <button type="submit" class="btn btn-primary btn-sm">
            <.icon name="hero-plus" class="h-4 w-4" /> Add
          </button>
        </form>
      </div>
    </div>
    """
  end

  defp step_review(assigns) do
    selected_db =
      if assigns.selected_database do
        Enum.find(assigns.managed_databases, &(&1["id"] == assigns.selected_database))
      end

    assigns = assign(assigns, :selected_db, selected_db)

    ~H"""
    <div class="space-y-4">
      <h2 class="card-title">Review & Create</h2>

      <div class="overflow-x-auto">
        <table class="table">
          <tbody>
            <tr>
              <th class="w-1/3">App Name</th>
              <td class="font-mono">{@app_name}</td>
            </tr>
            <tr>
              <th>Container Image</th>
              <td class="font-mono">{@registry["name"]}/{@selected_repo}:{@selected_tag}</td>
            </tr>
            <tr>
              <th>Auto-deploy</th>
              <td>
                <%= if @auto_deploy do %>
                  <span class="badge badge-success">Enabled</span>
                <% else %>
                  <span class="badge badge-ghost">Disabled</span>
                <% end %>
              </td>
            </tr>
            <tr>
              <th>HTTP Port</th>
              <td>{@http_port}</td>
            </tr>
            <tr>
              <th>Database</th>
              <td>
                <%= if @database_type == "managed" and @selected_db do %>
                  <span class="badge badge-success">Managed</span>
                  {@selected_db["name"]} ({@selected_db["engine"]})
                <% else %>
                  <span class="text-base-content/60">None</span>
                <% end %>
              </td>
            </tr>
            <tr>
              <th>Environment Variables</th>
              <td>
                <%= if @env_vars != [] do %>
                  <div class="flex flex-wrap gap-1">
                    <%= for env <- @env_vars do %>
                      <span class="badge badge-ghost badge-sm font-mono">{env["key"]}</span>
                    <% end %>
                  </div>
                <% else %>
                  <span class="text-base-content/60">None (only auto-generated)</span>
                <% end %>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div class="alert alert-info">
        <.icon name="hero-information-circle" class="h-5 w-5" />
        <div>
          <p class="font-medium">What will happen:</p>
          <ul class="list-disc list-inside text-sm mt-1">
            <li>Create Dokku app "{@app_name}"</li>
            <%= if @database_type == "managed" and @selected_db do %>
              <li>Create database user and database on {@selected_db["name"]}</li>
              <li>Add droplet to database trusted sources</li>
              <li>Set DATABASE_URL environment variable</li>
            <% end %>
            <li>Set environment variables (including SECRET_KEY_BASE)</li>
            <li>Configure port mapping (80 -> {@http_port})</li>
            <li>Deploy from container image</li>
          </ul>
        </div>
      </div>
    </div>
    """
  end

  defp deploy_result(assigns) do
    ~H"""
    <div class="space-y-4">
      <%= if @deploy_success do %>
        <div role="alert" class="alert alert-success">
          <.icon name="hero-check-circle" class="h-5 w-5" />
          <div>
            <h3 class="font-bold">App deployed successfully!</h3>
            <p class="text-sm">Your app "{@app_name}" is now running.</p>
          </div>
          <.link
            navigate={~p"/digitalocean/dokku/#{@droplet_id}/apps/#{@app_name}"}
            class="btn btn-sm btn-success"
          >
            View App <.icon name="hero-arrow-right" class="h-4 w-4" />
          </.link>
        </div>
      <% else %>
        <div role="alert" class="alert alert-error">
          <.icon name="hero-x-circle" class="h-5 w-5" />
          <div>
            <h3 class="font-bold">Deployment failed</h3>
            <p class="text-sm">See the output below for details.</p>
          </div>
        </div>
      <% end %>

      <div class="collapse collapse-open bg-base-200">
        <div class="collapse-title font-medium flex items-center gap-2">
          <.icon name="hero-command-line" class="h-5 w-5" />
          Deploy Output
        </div>
        <div class="collapse-content">
          <pre class="bg-base-300 p-4 rounded-lg overflow-x-auto text-sm font-mono whitespace-pre-wrap max-h-96 overflow-y-auto"><code>{@deploy_output}</code></pre>
        </div>
      </div>
    </div>
    """
  end

  # Get the digest for a specific tag from the tags list
  defp get_current_digest(tags, selected_tag) do
    case Enum.find(tags, &(&1["tag"] == selected_tag)) do
      nil -> nil
      tag -> tag["manifest_digest"]
    end
  end
end
