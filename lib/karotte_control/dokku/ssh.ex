defmodule KarotteControl.Dokku.SSH do
  @moduledoc """
  SSH client for executing Dokku commands on remote droplets.

  Uses SSH ControlMaster for connection multiplexing to reuse connections.
  """

  alias KarotteControl.Dokku.{Credentials, SSHCredential}
  alias KarotteControl.DigitalOcean.Droplets

  @doc """
  Lists all Dokku apps on a droplet.
  Returns {:ok, [app_names]} or {:error, reason}
  """
  def list_apps(droplet_id) do
    case run_dokku_command(droplet_id, "apps:list") do
      {:ok, output} ->
        apps =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&skip_line?/1)
          |> Enum.filter(&valid_app_name?/1)

        {:ok, apps}

      error ->
        error
    end
  end

  # Lines to skip when parsing Dokku command output
  defp skip_line?(line) do
    line == "" or
      String.starts_with?(line, "=====>") or
      String.starts_with?(line, "Warning:") or
      String.starts_with?(line, "!") or
      String.contains?(line, "known hosts") or
      String.contains?(line, "haven't deployed")
  end

  # Validate that a line looks like a valid Dokku app name
  # App names must be lowercase alphanumeric and can contain hyphens
  defp valid_app_name?(name) do
    String.match?(name, ~r/^[a-z][a-z0-9-]*$/)
  end

  @doc """
  Gets detailed info about a Dokku app.
  """
  def app_info(droplet_id, app_name) do
    case run_dokku_command(droplet_id, "ps:report #{app_name}") do
      {:ok, output} -> {:ok, parse_report(output)}
      error -> error
    end
  end

  @doc """
  Gets the app's URL/domains.
  """
  def app_domains(droplet_id, app_name) do
    case run_dokku_command(droplet_id, "domains:report #{app_name}") do
      {:ok, output} -> {:ok, parse_report(output)}
      error -> error
    end
  end

  @doc """
  Checks if Dokku is installed on a droplet.
  """
  def dokku_installed?(droplet_id) do
    case run_command(droplet_id, "dokku version") do
      {:ok, output} -> String.contains?(output, "dokku version")
      _ -> false
    end
  end

  @doc """
  Gets Dokku version.
  """
  def version(droplet_id) do
    case run_command(droplet_id, "dokku version") do
      {:ok, output} ->
        version =
          output
          |> String.trim()
          |> String.replace("dokku version ", "")

        {:ok, version}

      error ->
        error
    end
  end

  @doc """
  Restarts a Dokku app.
  """
  def restart_app(droplet_id, app_name) do
    run_dokku_command(droplet_id, "ps:restart #{app_name}")
  end

  @doc """
  Restarts a Dokku app with streaming output.
  Sends {:ssh_output, chunk} messages to the caller as output arrives.
  Returns {:ok, full_output} or {:error, reason} when complete.
  """
  def restart_app_stream(droplet_id, app_name, caller_pid) do
    run_dokku_command_stream(droplet_id, "ps:restart #{app_name}", caller_pid)
  end

  @doc """
  Stops a Dokku app.
  """
  def stop_app(droplet_id, app_name) do
    run_dokku_command(droplet_id, "ps:stop #{app_name}")
  end

  @doc """
  Starts a Dokku app.
  """
  def start_app(droplet_id, app_name) do
    run_dokku_command(droplet_id, "ps:start #{app_name}")
  end

  @doc """
  Gets app environment variables.
  """
  def get_env(droplet_id, app_name) do
    case run_dokku_command(droplet_id, "config:show #{app_name}") do
      {:ok, output} ->
        envs =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&skip_line?/1)
          |> Enum.map(fn line ->
            case String.split(line, ":", parts: 2) do
              [key, value] ->
                {String.trim(key), String.trim(value)}

              _ ->
                nil
            end
          end)
          |> Enum.reject(&is_nil/1)
          |> Map.new()

        {:ok, envs}

      error ->
        error
    end
  end

  @doc """
  Sets an environment variable for an app.
  Uses --no-restart by default to avoid long waits. Call restart_app separately if needed.
  """
  def set_env(droplet_id, app_name, key, value, opts \\ []) do
    restart = Keyword.get(opts, :restart, false)
    restart_flag = if restart, do: "", else: "--no-restart "
    # Escape the value for shell
    escaped_value = String.replace(value, "'", "'\\''")
    run_dokku_command(droplet_id, "config:set #{restart_flag}#{app_name} #{key}='#{escaped_value}'")
  end

  @doc """
  Unsets an environment variable for an app.
  Uses --no-restart by default to avoid long waits. Call restart_app separately if needed.
  """
  def unset_env(droplet_id, app_name, key, opts \\ []) do
    restart = Keyword.get(opts, :restart, false)
    restart_flag = if restart, do: "", else: "--no-restart "
    run_dokku_command(droplet_id, "config:unset #{restart_flag}#{app_name} #{key}")
  end

  @doc """
  Sets multiple environment variables for an app at once.
  env_vars should be a map of %{key => value}
  """
  def set_env_vars(droplet_id, app_name, env_vars) when is_map(env_vars) do
    if map_size(env_vars) == 0 do
      {:ok, ""}
    else
      env_string =
        env_vars
        |> Enum.map(fn {key, value} ->
          escaped_value = String.replace(value, "'", "'\\''")
          "#{key}='#{escaped_value}'"
        end)
        |> Enum.join(" ")

      run_dokku_command(droplet_id, "config:set --no-restart #{app_name} #{env_string}")
    end
  end

  @doc """
  Creates a new Dokku app.
  """
  def create_app(droplet_id, app_name) do
    run_dokku_command(droplet_id, "apps:create #{app_name}")
  end

  @doc """
  Destroys a Dokku app.
  """
  def destroy_app(droplet_id, app_name) do
    run_dokku_command(droplet_id, "apps:destroy #{app_name} --force")
  end

  @doc """
  Lists available Postgres databases.
  """
  def list_postgres_databases(droplet_id) do
    case run_dokku_command(droplet_id, "postgres:list") do
      {:ok, output} ->
        databases =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&skip_line?/1)
          |> Enum.filter(&valid_app_name?/1)

        {:ok, databases}

      error ->
        error
    end
  end

  @doc """
  Links a Postgres database to an app.
  """
  def link_postgres(droplet_id, app_name, database_name) do
    run_dokku_command(droplet_id, "postgres:link #{database_name} #{app_name}")
  end

  @doc """
  Deploys an app from a Docker image.
  """
  def deploy_from_image(droplet_id, app_name, image_url) do
    run_dokku_command(droplet_id, "git:from-image #{app_name} #{image_url}")
  end

  @doc """
  Sets the port mapping for an app.
  """
  def set_port(droplet_id, app_name, host_port, container_port) do
    run_dokku_command(droplet_id, "ports:set #{app_name} http:#{host_port}:#{container_port}")
  end

  @doc """
  Sets a domain for an app.
  """
  def add_domain(droplet_id, app_name, domain) do
    run_dokku_command(droplet_id, "domains:add #{app_name} #{domain}")
  end

  @doc """
  Enables Let's Encrypt SSL for an app.
  """
  def enable_letsencrypt(droplet_id, app_name) do
    run_dokku_command(droplet_id, "letsencrypt:enable #{app_name}")
  end

  @doc """
  Checks if the postgres plugin is installed.
  """
  def postgres_plugin_installed?(droplet_id) do
    case run_dokku_command(droplet_id, "plugin:list") do
      {:ok, output} -> String.contains?(output, "postgres")
      _ -> false
    end
  end

  @doc """
  Logs into a Docker registry using docker login.
  """
  def docker_login(droplet_id, registry, username, password) do
    escaped_password = String.replace(password, "'", "'\\''")
    run_command(droplet_id, "echo '#{escaped_password}' | docker login #{registry} -u #{username} --password-stdin")
  end

  @doc """
  Logs into a Docker registry using Dokku's registry:login command.
  For DigitalOcean, both username and password should be the API token.
  """
  def registry_login(droplet_id, registry, username, password) do
    escaped_password = String.replace(password, "'", "'\\''")
    run_dokku_command(droplet_id, "registry:login #{registry} #{username} '#{escaped_password}'")
  end

  # Private functions

  defp run_dokku_command(droplet_id, command) do
    run_command(droplet_id, "dokku #{command}")
  end

  defp run_command(droplet_id, command) do
    with {:ok, credential} <- get_credential(droplet_id),
         {:ok, ip} <- get_droplet_ip(droplet_id) do
      execute_ssh(ip, credential, command)
    end
  end

  defp get_credential(droplet_id) do
    case Credentials.get_by_droplet_id(droplet_id) do
      nil -> {:error, :no_credentials}
      credential -> {:ok, credential}
    end
  end

  defp get_droplet_ip(droplet_id) do
    with {:ok, droplet} <- Droplets.get(droplet_id) do
      Droplets.get_public_ip(droplet)
    end
  end

  defp execute_ssh(ip, %SSHCredential{} = credential, command) do
    # Use a persistent key file per droplet to enable ControlMaster connection reuse
    key_path = get_or_create_key_file(ip, credential)
    control_path = control_socket_path(ip, credential.ssh_port)

    args = [
      "-i",
      key_path,
      "-o",
      "StrictHostKeyChecking=no",
      "-o",
      "UserKnownHostsFile=/dev/null",
      "-o",
      "ConnectTimeout=10",
      # ControlMaster settings for connection reuse
      "-o",
      "ControlMaster=auto",
      "-o",
      "ControlPath=#{control_path}",
      "-o",
      "ControlPersist=300",
      "-p",
      to_string(credential.ssh_port),
      "#{credential.ssh_user}@#{ip}",
      command
    ]

    case System.cmd("ssh", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _code} -> {:error, output}
    end
  end

  # Get or create a persistent key file for SSH connection reuse
  defp get_or_create_key_file(ip, credential) do
    key_dir = Path.join(System.tmp_dir!(), "karotte_ssh_keys")
    File.mkdir_p!(key_dir)

    # Use a hash of ip+port as filename to avoid special characters
    key_id = :crypto.hash(:md5, "#{ip}:#{credential.ssh_port}") |> Base.encode16(case: :lower)
    key_path = Path.join(key_dir, "key_#{key_id}")

    # Only write if file doesn't exist or content changed
    unless File.exists?(key_path) and File.read!(key_path) == credential.ssh_private_key do
      File.write!(key_path, credential.ssh_private_key)
      File.chmod!(key_path, 0o600)
    end

    key_path
  end

  defp control_socket_path(ip, port) do
    # Use /tmp directly with short names to avoid Unix socket path length limit (~104 chars)
    socket_dir = "/tmp/kssh"
    File.mkdir_p!(socket_dir)
    # Use short hash to keep path under limit
    hash = :crypto.hash(:md5, "#{ip}:#{port}") |> Base.encode16(case: :lower) |> binary_part(0, 8)
    Path.join(socket_dir, hash)
  end

  defp parse_report(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      case String.split(line, ":", parts: 2) do
        [key, value] -> {String.trim(key), String.trim(value)}
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Map.new()
  end

  # Streaming command execution

  defp run_dokku_command_stream(droplet_id, command, caller_pid) do
    run_command_stream(droplet_id, "dokku #{command}", caller_pid)
  end

  defp run_command_stream(droplet_id, command, caller_pid) do
    with {:ok, credential} <- get_credential(droplet_id),
         {:ok, ip} <- get_droplet_ip(droplet_id) do
      execute_ssh_stream(ip, credential, command, caller_pid)
    end
  end

  defp execute_ssh_stream(ip, %SSHCredential{} = credential, command, caller_pid) do
    key_path = get_or_create_key_file(ip, credential)
    control_path = control_socket_path(ip, credential.ssh_port)

    args = [
      "-i",
      key_path,
      "-o",
      "StrictHostKeyChecking=no",
      "-o",
      "UserKnownHostsFile=/dev/null",
      "-o",
      "ConnectTimeout=10",
      "-o",
      "ControlMaster=auto",
      "-o",
      "ControlPath=#{control_path}",
      "-o",
      "ControlPersist=300",
      "-p",
      to_string(credential.ssh_port),
      "#{credential.ssh_user}@#{ip}",
      command
    ]

    port = Port.open({:spawn_executable, System.find_executable("ssh")}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      args: args
    ])

    collect_port_output(port, caller_pid, [])
  end

  defp collect_port_output(port, caller_pid, acc) do
    receive do
      {^port, {:data, data}} ->
        # Send chunk to caller for live updates
        send(caller_pid, {:ssh_output, data})
        collect_port_output(port, caller_pid, [data | acc])

      {^port, {:exit_status, 0}} ->
        {:ok, acc |> Enum.reverse() |> Enum.join()}

      {^port, {:exit_status, _code}} ->
        {:error, acc |> Enum.reverse() |> Enum.join()}
    after
      120_000 ->
        Port.close(port)
        {:error, "SSH command timed out"}
    end
  end
end
