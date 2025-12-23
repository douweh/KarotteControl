defmodule KarotteControl.Dokku.SSH do
  @moduledoc """
  SSH client for executing Dokku commands on remote droplets.
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
    case run_dokku_command(droplet_id, "config:export #{app_name}") do
      {:ok, output} ->
        envs =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(fn line ->
            case String.split(line, "=", parts: 2) do
              [key, value] ->
                # Remove surrounding quotes if present
                value = value |> String.trim("'") |> String.trim("\"")
                {key, value}

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
  """
  def set_env(droplet_id, app_name, key, value) do
    # Escape the value for shell
    escaped_value = String.replace(value, "'", "'\\''")
    run_dokku_command(droplet_id, "config:set #{app_name} #{key}='#{escaped_value}'")
  end

  @doc """
  Unsets an environment variable for an app.
  """
  def unset_env(droplet_id, app_name, key) do
    run_dokku_command(droplet_id, "config:unset #{app_name} #{key}")
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
    # Write the private key to a temporary file
    key_path = Path.join(System.tmp_dir!(), "dokku_key_#{:erlang.unique_integer([:positive])}")

    try do
      File.write!(key_path, credential.ssh_private_key)
      File.chmod!(key_path, 0o600)

      args = [
        "-i",
        key_path,
        "-o",
        "StrictHostKeyChecking=no",
        "-o",
        "UserKnownHostsFile=/dev/null",
        "-o",
        "ConnectTimeout=10",
        "-p",
        to_string(credential.ssh_port),
        "#{credential.ssh_user}@#{ip}",
        command
      ]

      case System.cmd("ssh", args, stderr_to_stdout: true) do
        {output, 0} -> {:ok, output}
        {output, _code} -> {:error, output}
      end
    after
      File.rm(key_path)
    end
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
end
