defmodule KarotteControl.DigitalOcean.Droplets do
  @moduledoc """
  DigitalOcean Droplets API client.
  """

  alias KarotteControl.DigitalOcean.Client

  @doc """
  Lists all droplets.
  """
  def list do
    case Client.get("/droplets") do
      {:ok, %{"droplets" => droplets}} -> {:ok, droplets}
      {:ok, %{}} -> {:ok, []}
      error -> error
    end
  end

  @doc """
  Lists droplets filtered by tag.
  """
  def list_by_tag(tag) do
    case Client.get("/droplets?tag_name=#{tag}") do
      {:ok, %{"droplets" => droplets}} -> {:ok, droplets}
      {:ok, %{}} -> {:ok, []}
      error -> error
    end
  end

  @doc """
  Gets a single droplet by ID.
  """
  def get(droplet_id) do
    case Client.get("/droplets/#{droplet_id}") do
      {:ok, %{"droplet" => droplet}} -> {:ok, droplet}
      error -> error
    end
  end

  @doc """
  Gets the public IPv4 address of a droplet.
  """
  def get_public_ip(droplet) do
    networks = droplet["networks"]["v4"] || []

    case Enum.find(networks, &(&1["type"] == "public")) do
      %{"ip_address" => ip} -> {:ok, ip}
      nil -> {:error, :no_public_ip}
    end
  end
end
