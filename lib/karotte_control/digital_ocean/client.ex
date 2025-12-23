defmodule KarotteControl.DigitalOcean.Client do
  @moduledoc """
  HTTP client for the DigitalOcean API.
  """

  @base_url "https://api.digitalocean.com/v2"

  def get(path, opts \\ []) do
    request(:get, path, opts)
  end

  def post(path, body, opts \\ []) do
    request(:post, path, Keyword.put(opts, :json, body))
  end

  def put(path, body, opts \\ []) do
    request(:put, path, Keyword.put(opts, :json, body))
  end

  def delete(path, opts \\ []) do
    request(:delete, path, opts)
  end

  defp request(method, path, opts) do
    url = @base_url <> path

    req_opts =
      [
        method: method,
        url: url,
        headers: [
          {"authorization", "Bearer #{api_token()}"},
          {"content-type", "application/json"}
        ]
      ] ++ opts

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp api_token do
    Application.get_env(:karotte_control, :digitalocean_api_token) ||
      raise "DigitalOcean API token not configured. Set DIGITALOCEAN_API_TOKEN in your .env file."
  end

  @doc """
  Returns the DigitalOcean API token.
  Used for authenticating with the container registry.
  """
  def get_api_token do
    api_token()
  end
end
