defmodule KarotteControlWeb.DigitalOcean.AppNewLive do
  use KarotteControlWeb, :live_view

  alias KarotteControl.DigitalOcean.{Apps, Registry, Databases, Projects}

  @impl true
  def mount(%{"project_id" => project_id}, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Create App")
      |> assign(:project_id, project_id)
      |> assign(:step, 1)
      |> assign(:loading, true)
      |> assign(:creating, false)
      |> assign(:create_status, nil)
      |> assign(:error, nil)
      # Step 1: Basic info
      |> assign(:app_name, "")
      |> assign(:regions, [])
      |> assign(:selected_region, "ams")
      # Step 2: Container image
      |> assign(:registry, nil)
      |> assign(:repositories, [])
      |> assign(:selected_repo, nil)
      |> assign(:tags, [])
      |> assign(:selected_tag, nil)
      |> assign(:http_port, "4000")
      # Step 3: Database
      |> assign(:database_type, "none")
      |> assign(:managed_databases, [])
      |> assign(:selected_database, nil)
      |> assign(:dev_db_name, "")
      # Step 4: Environment variables
      |> assign(:env_vars, [])
      |> assign(:new_env_key, "")
      |> assign(:new_env_value, "")
      |> assign(:new_env_type, "GENERAL")
      # Step 5: Instance size
      |> assign(:instance_sizes, [])
      |> assign(:selected_size, "apps-s-1vcpu-0.5gb")

    if connected?(socket) do
      send(self(), :load_initial_data)
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:load_initial_data, socket) do
    project_id = socket.assigns.project_id

    socket =
      with {:ok, project} <- Projects.get(project_id),
           {:ok, regions} <- Apps.list_regions(),
           {:ok, registry} <- Registry.get(),
           {:ok, repositories} <- Registry.list_repositories(registry["name"]),
           {:ok, databases} <- Databases.list(),
           {:ok, instance_sizes} <- Apps.list_instance_sizes() do
        # Filter to only show service-compatible sizes
        # Note: API returns both "cpus" and "memory_bytes" as strings
        service_sizes =
          instance_sizes
          |> Enum.filter(&(&1["tier_slug"] in ["basic", "professional"]))
          |> Enum.filter(&(is_binary(&1["cpus"]) and is_binary(&1["memory_bytes"])))
          |> Enum.sort_by(fn size ->
            cpus = String.to_integer(size["cpus"])
            memory_bytes = String.to_integer(size["memory_bytes"])
            cpus * 1000 + memory_bytes / 1_073_741_824
          end)

        socket
        |> assign(:page_title, "Create App in #{project["name"]}")
        |> assign(:regions, regions)
        |> assign(:registry, registry)
        |> assign(:repositories, repositories)
        |> assign(:managed_databases, databases)
        |> assign(:instance_sizes, service_sizes)
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
  def handle_event("update_field", params, socket) do
    socket =
      cond do
        # Handle phx-click style events with field/value
        Map.has_key?(params, "field") and Map.has_key?(params, "value") ->
          field = params["field"]
          value = params["value"]

          case field do
            "app_name" -> assign(socket, :app_name, value)
            "selected_region" -> assign(socket, :selected_region, value)
            "http_port" -> assign(socket, :http_port, value)
            "database_type" -> assign(socket, :database_type, value)
            "selected_database" -> assign(socket, :selected_database, value)
            "selected_size" -> assign(socket, :selected_size, value)
            _ -> socket
          end

        # Handle form change events (phx-change on form)
        true ->
          socket
          |> maybe_assign(:database_type, params["database_type"])
          |> maybe_assign(:selected_database, params["selected_database"])
      end

    {:noreply, socket}
  end

  defp maybe_assign(socket, _key, nil), do: socket
  defp maybe_assign(socket, key, value), do: assign(socket, key, value)

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
      new_env = %{"key" => key, "value" => value, "type" => type, "scope" => "RUN_AND_BUILD_TIME"}
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

    # Validate current step
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

  @impl true
  def handle_info(:do_create_app, socket) do
    if socket.assigns.database_type == "managed" do
      send(self(), {:create_step, :create_user})
    else
      send(self(), {:create_step, :create_app})
    end

    {:noreply, socket}
  end

  def handle_info({:create_step, :create_user}, socket) do
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
      send(self(), {:create_step, :create_database})
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:creating, false)
       |> assign(:create_status, nil)
       |> put_flash(:error, "Failed to create database user: #{inspect(result)}")}
    end
  end

  def handle_info({:create_step, :create_database}, socket) do
    socket = assign(socket, :create_status, "Creating database...")

    db = Enum.find(socket.assigns.managed_databases, &(&1["id"] == socket.assigns.selected_database))
    db_name = "db-#{socket.assigns.app_name}"
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
      {:noreply, socket}
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
    db_name = "db-#{socket.assigns.app_name}"
    username = socket.assigns.app_name

    # Fetch full cluster details including connection info
    case Databases.get(db["id"]) do
      {:ok, cluster} ->
        case Databases.grant_privileges(cluster, db_name, username) do
          :ok ->
            send(self(), {:create_step, :create_app})
            {:noreply, socket}

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

  def handle_info({:create_step, :create_app}, socket) do
    socket = assign(socket, :create_status, "Creating app on DigitalOcean...")

    spec = build_app_spec(socket.assigns)

    case Apps.create(spec) do
      {:ok, app} ->
        if socket.assigns.database_type == "managed" do
          send(self(), {:create_step, :add_trusted_source, app})
        else
          send(self(), {:create_step, :assign_to_project, app})
        end

        {:noreply, socket}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:creating, false)
         |> assign(:create_status, nil)
         |> put_flash(:error, "Failed to create app: #{inspect(reason)}")}
    end
  end

  def handle_info({:create_step, :add_trusted_source, app}, socket) do
    socket = assign(socket, :create_status, "Adding app to database trusted sources...")

    db = Enum.find(socket.assigns.managed_databases, &(&1["id"] == socket.assigns.selected_database))
    Databases.add_app_to_trusted_sources(db["id"], app["id"])

    send(self(), {:create_step, :assign_to_project, app})
    {:noreply, socket}
  end

  def handle_info({:create_step, :assign_to_project, app}, socket) do
    socket = assign(socket, :create_status, "Adding app to project...")

    app_urn = "do:app:#{app["id"]}"
    Projects.assign_resources(socket.assigns.project_id, [app_urn])

    {:noreply,
     socket
     |> put_flash(:info, "App created successfully!")
     |> push_navigate(to: ~p"/digitalocean/apps/#{app["id"]}")}
  end

  defp validate_step(socket, step) do
    case step do
      1 ->
        cond do
          String.trim(socket.assigns.app_name) == "" ->
            {:error, "App name is required"}

          not Regex.match?(~r/^[a-z][a-z0-9-]{1,30}[a-z0-9]$/, socket.assigns.app_name) ->
            {:error, "App name must be 2-32 lowercase letters, numbers, and hyphens"}

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

  defp build_app_spec(assigns) do
    registry_name = assigns.registry["name"]
    db_ref_name = "db-#{assigns.app_name}"

    # Generate a secret key base
    secret_key_base = :crypto.strong_rand_bytes(64) |> Base.encode64() |> binary_part(0, 64)

    # App-level envs - available to all components (services, jobs, workers)
    app_envs = [
      %{
        "key" => "SECRET_KEY_BASE",
        "scope" => "RUN_TIME",
        "type" => "SECRET",
        "value" => secret_key_base
      }
    ]

    # Add DATABASE_URL at app level if using managed database
    app_envs =
      if assigns.database_type == "managed" do
        app_envs ++
          [
            %{
              "key" => "DATABASE_URL",
              "scope" => "RUN_TIME",
              "value" => "${#{db_ref_name}.DATABASE_URL}"
            }
          ]
      else
        app_envs
      end

    # Add user-provided env vars
    app_envs = app_envs ++ assigns.env_vars

    # Base service config
    service = %{
      "name" => assigns.app_name,
      "image" => %{
        "registry_type" => "DOCR",
        "repository" => assigns.selected_repo,
        "tag" => assigns.selected_tag,
        "registry" => registry_name,
        "deploy_on_push" => %{"enabled" => true}
      },
      "instance_size_slug" => assigns.selected_size,
      "instance_count" => 1,
      "http_port" => String.to_integer(assigns.http_port)
    }

    spec = %{
      "name" => assigns.app_name,
      "region" => assigns.selected_region,
      "envs" => app_envs,
      "services" => [service]
    }

    # Add database and migration job if selected
    case assigns.database_type do
      "managed" ->
        db = Enum.find(assigns.managed_databases, &(&1["id"] == assigns.selected_database))

        if db do
          # Use db-{app_name} for the database name to avoid conflicts with service name
          # User keeps the app_name
          db_spec = %{
            "name" => db_ref_name,
            "cluster_name" => db["name"],
            "db_name" => db_ref_name,
            "db_user" => assigns.app_name,
            "engine" => String.upcase(db["engine"]),
            "production" => true
          }

          # Migration job that runs after deploy
          migrate_job = %{
            "name" => "migrate",
            "kind" => "POST_DEPLOY",
            "image" => %{
              "registry_type" => "DOCR",
              "repository" => assigns.selected_repo,
              "tag" => assigns.selected_tag,
              "registry" => registry_name,
              "deploy_on_push" => %{"enabled" => true}
            },
            "instance_size_slug" => "apps-s-1vcpu-0.5gb",
            "instance_count" => 1,
            "run_command" => "./bin/migrate"
          }

          spec
          |> Map.put("databases", [db_spec])
          |> Map.put("jobs", [migrate_job])
        else
          spec
        end

      _ ->
        spec
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
                  <.step_basic_info
                    app_name={@app_name}
                    regions={@regions}
                    selected_region={@selected_region}
                  />
                <% 2 -> %>
                  <.step_container
                    registry={@registry}
                    repositories={@repositories}
                    selected_repo={@selected_repo}
                    tags={@tags}
                    selected_tag={@selected_tag}
                    http_port={@http_port}
                  />
                <% 3 -> %>
                  <.step_database
                    database_type={@database_type}
                    managed_databases={@managed_databases}
                    selected_database={@selected_database}
                    dev_db_name={@dev_db_name}
                  />
                <% 4 -> %>
                  <.step_env_vars
                    env_vars={@env_vars}
                    new_env_key={@new_env_key}
                    new_env_value={@new_env_value}
                    new_env_type={@new_env_type}
                  />
                <% 5 -> %>
                  <.step_review
                    app_name={@app_name}
                    selected_region={@selected_region}
                    registry={@registry}
                    selected_repo={@selected_repo}
                    selected_tag={@selected_tag}
                    http_port={@http_port}
                    database_type={@database_type}
                    dev_db_name={@dev_db_name}
                    managed_databases={@managed_databases}
                    selected_database={@selected_database}
                    instance_sizes={@instance_sizes}
                    selected_size={@selected_size}
                    env_vars={@env_vars}
                    creating={@creating}
                  />
              <% end %>

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
          <span class="label-text-alt">2-32 lowercase letters, numbers, and hyphens</span>
        </label>
      </div>

      <div class="form-control w-full max-w-md">
        <label class="label">
          <span class="label-text">Region</span>
        </label>
        <select
          class="select select-bordered w-full"
          phx-change="update_field"
          phx-value-field="selected_region"
          name="value"
        >
          <%= for region <- @regions do %>
            <option value={region["slug"]} selected={region["slug"] == @selected_region}>
              {region["label"]} ({region["slug"]})
            </option>
          <% end %>
        </select>
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
      <% end %>

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
            <p class="text-sm text-base-content/60">Connect to an existing managed database cluster</p>
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
        Add custom environment variables for your app. SECRET_KEY_BASE and DATABASE_URL (if using a database) are added automatically.
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

    selected_size = Enum.find(assigns.instance_sizes, &(&1["slug"] == assigns.selected_size))

    assigns =
      assigns
      |> assign(:selected_db, selected_db)
      |> assign(:selected_size_info, selected_size)

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
              <th>Region</th>
              <td>{@selected_region}</td>
            </tr>
            <tr>
              <th>Container Image</th>
              <td class="font-mono">{@registry["name"]}/{@selected_repo}:{@selected_tag}</td>
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

      <div class="form-control w-full max-w-md">
        <label class="label">
          <span class="label-text">Instance Size</span>
        </label>
        <select
          class="select select-bordered w-full"
          phx-change="update_field"
          phx-value-field="selected_size"
          name="value"
        >
          <%= for size <- @instance_sizes do %>
            <option value={size["slug"]} selected={size["slug"] == @selected_size}>
              {size["slug"]} - {size["cpus"]} vCPU,
              {Float.round(String.to_integer(size["memory_bytes"]) / 1_073_741_824, 1)} GB RAM
              (${size["usd_per_month"]}/mo)
            </option>
          <% end %>
        </select>
      </div>
    </div>
    """
  end
end
