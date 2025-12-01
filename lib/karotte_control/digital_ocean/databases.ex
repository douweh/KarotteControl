defmodule KarotteControl.DigitalOcean.Databases do
  @moduledoc """
  DigitalOcean Managed Databases API client.
  """

  alias KarotteControl.DigitalOcean.Client

  def list do
    case Client.get("/databases") do
      {:ok, %{"databases" => databases}} -> {:ok, databases}
      {:ok, %{}} -> {:ok, []}
      error -> error
    end
  end

  def get(database_id) do
    case Client.get("/databases/#{database_id}") do
      {:ok, %{"database" => database}} -> {:ok, database}
      error -> error
    end
  end

  def list_dbs(cluster_id) do
    case Client.get("/databases/#{cluster_id}/dbs") do
      {:ok, %{"dbs" => dbs}} -> {:ok, dbs}
      {:ok, %{}} -> {:ok, []}
      error -> error
    end
  end

  def list_users(cluster_id) do
    case Client.get("/databases/#{cluster_id}/users") do
      {:ok, %{"users" => users}} -> {:ok, users}
      {:ok, %{}} -> {:ok, []}
      error -> error
    end
  end

  def list_pools(cluster_id) do
    case Client.get("/databases/#{cluster_id}/pools") do
      {:ok, %{"pools" => pools}} -> {:ok, pools}
      {:ok, %{}} -> {:ok, []}
      error -> error
    end
  end

  @doc """
  Creates a new database in the cluster.
  """
  def create_db(cluster_id, db_name) do
    case Client.post("/databases/#{cluster_id}/dbs", %{"name" => db_name}) do
      {:ok, %{"db" => db}} -> {:ok, db}
      error -> error
    end
  end

  @doc """
  Creates a new user in the cluster.
  """
  def create_user(cluster_id, username) do
    case Client.post("/databases/#{cluster_id}/users", %{"name" => username}) do
      {:ok, %{"user" => user}} -> {:ok, user}
      error -> error
    end
  end

  @doc """
  Gets the list of trusted sources (firewall rules) for the cluster.
  """
  def list_firewall_rules(cluster_id) do
    case Client.get("/databases/#{cluster_id}/firewall") do
      {:ok, %{"rules" => rules}} -> {:ok, rules}
      {:ok, %{}} -> {:ok, []}
      error -> error
    end
  end

  @doc """
  Updates the firewall rules for the cluster.
  Rules is a list of maps with "type" and "value" keys.
  Type can be: "droplet", "k8s", "ip_addr", "tag", or "app"
  """
  def update_firewall_rules(cluster_id, rules) do
    Client.put("/databases/#{cluster_id}/firewall", %{"rules" => rules})
  end

  @doc """
  Adds an app to the trusted sources of a database cluster.
  Returns the updated list of rules.
  """
  def add_app_to_trusted_sources(cluster_id, app_id) do
    with {:ok, existing_rules} <- list_firewall_rules(cluster_id) do
      # Check if app is already trusted
      app_already_trusted =
        Enum.any?(existing_rules, fn rule ->
          rule["type"] == "app" && rule["value"] == app_id
        end)

      if app_already_trusted do
        {:ok, existing_rules}
      else
        new_rules = existing_rules ++ [%{"type" => "app", "value" => app_id}]
        update_firewall_rules(cluster_id, new_rules)
      end
    end
  end

  @doc """
  Grants full privileges on a database to a user.
  Connects as doadmin and grants all privileges needed for the app to work.
  """
  def grant_privileges(cluster, db_name, username) do
    # Build connection URI from cluster info
    connection = cluster["connection"]
    host = connection["host"]
    port = connection["port"]
    admin_user = connection["user"]
    admin_password = connection["password"]

    # Build psql connection string for doadmin
    conn_string =
      "postgresql://#{admin_user}:#{URI.encode_www_form(admin_password)}@#{host}:#{port}/#{db_name}?sslmode=require"

    # SQL commands to grant privileges
    # The key is to make the user the OWNER of the public schema
    # This gives them full control to create tables, run migrations, etc.
    sql = """
    GRANT ALL PRIVILEGES ON DATABASE "#{db_name}" TO "#{username}";
    ALTER SCHEMA public OWNER TO "#{username}";
    GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO "#{username}";
    GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO "#{username}";
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO "#{username}";
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO "#{username}";
    """

    # Execute via psql
    case System.cmd("psql", [conn_string, "-c", sql], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {error, _code} -> {:error, error}
    end
  end
end
